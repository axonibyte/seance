#!/bin/sh
# Tier 4 -- failback, and the guard that stands between it and the crash window.
#
# `zfs recv -F` rolls the origin's live dataset back to the incremental base
# before rolling it forward, so everything written to the origin's copy since
# that base is destroyed by the receive. seance measures it first and refuses,
# printing the byte count, unless the operator says `--discard-origin-writes`.
#
# That guard is the single most destructive decision in the product, and until
# this file existed its only exercise was a reaper session. Here it is driven
# on a workstation: the real failback_run, the real transport, the real
# receive command line -- with the interim host and the local pool standing in
# as scripts, for the reasons set out at length in tests/tier4/t_ladder.sh.
#
# The guest is arc01 because the mock's arc01 is HELD, which is the state a
# failback is allowed to start from. A failback under a running guest is
# refused, and that refusal is asserted too.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SEANCE_ROOT=${T_ROOT}
export SEANCE_ROOT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/common.subr
. "${T_ROOT}/lib/common.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/policy.subr
. "${T_ROOT}/lib/policy.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/conf.subr
. "${T_ROOT}/lib/conf.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/transport.subr
. "${T_ROOT}/lib/transport.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/notify.subr
. "${T_ROOT}/lib/notify.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/zfs.subr
. "${T_ROOT}/lib/zfs.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/lineage.subr
. "${T_ROOT}/lib/lineage.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/repl.subr
. "${T_ROOT}/lib/repl.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/status.subr
. "${T_ROOT}/lib/status.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/gate.subr
. "${T_ROOT}/lib/gate.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/promote.subr
. "${T_ROOT}/lib/promote.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/failback.subr
. "${T_ROOT}/lib/failback.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../mock-adapter.subr
. "${T_ROOT}/tests/mock-adapter.subr"

TAB=$( printf '\t.' )
TAB=${TAB%.}

SEANCE_TMP_REGISTRY=$( t_tmpdir )/registry
: > "${SEANCE_TMP_REGISTRY}"
export SEANCE_TMP_REGISTRY
t_at_exit 'seance_tmp_cleanup'

NOTIFY_TIMEOUT=1

# The lineage: two snapshots at home, and on the interim the newer of those
# plus the final one the assist took before handing the guest back.
T1=$( pol_epoch_to_ts 1786000000 )
T2=$( pol_epoch_to_ts 1786003600 )
T3=$( pol_epoch_to_ts 1786007200 )

ORIGIN_DS=pool0/arc01
INTERIM_DS=standby0/alpha/arc01
BASE="seance-alpha-${T2}"
FINAL="seance-bravo-${T3}"

# ---------------------------------------------------------------------------
# The world: an interim host that answers, and a pool that does as it is told
# ---------------------------------------------------------------------------

SHIM=$( t_tmpdir )/bin
mkdir -p "${SHIM}"

cat > "${SHIM}/ssh" <<'EOF'
#!/bin/sh
# The interim host. Everything it is asked is one of five things, and each of
# them is logged so the caller can assert the ORDER as well as the answers --
# a failback that unregistered before it received would be a failback that had
# thrown the data away.
set -u
# The target is the argument just before the command, which is the shape every
# seance_ssh call has. Scanning for "*@*" instead would find the '@' inside a
# snapshot name in the command itself.
prev=""
cur=""
for a in "$@"; do
    prev=${cur}
    cur=$a
done
addr=${prev#*@}
cmd=${cur}

printf '%s\n' "${cmd}" >> "${WORLD_DIR}/ssh.log"

case " ${WORLD_SSH_ALIVE:-} " in
    *" ${addr} "*) ;;
    *) echo "ssh: connect to host ${addr}: Connection refused" >&2; exit 255 ;;
esac

# The interim goes away in the middle. WORLD_SSH_DEAF_AFTER names the assist
# step it answers LAST: that call succeeds, and everything after it -- the
# snapshot listing, the reverse send, the unregister -- is a connection
# refused, which is what an interim losing its uplink looks like from here.
if [ -n "${WORLD_SSH_DEAF_AFTER:-}" ]; then
    if [ -f "${WORLD_DIR}/deaf" ]; then
        echo "ssh: connect to host ${addr}: Connection refused" >&2
        exit 255
    fi
    case "${cmd}" in
        *"failback-assist "*" ${WORLD_SSH_DEAF_AFTER}") : > "${WORLD_DIR}/deaf" ;;
    esac
fi

case "${cmd}" in
    "exit 0")
        exit 0
        ;;
    "seance placement")
        [ -r "${WORLD_DIR}/claims.${addr}" ] && cat "${WORLD_DIR}/claims.${addr}"
        echo "placement: answered"
        exit 0
        ;;
    *"failback-assist "*" stop")
        echo "failback-assist: stopped the guest"
        exit 0
        ;;
    *"failback-assist "*" snapshot")
        # WORLD_SNAP_MUTE: the interim says it snapshotted and does not say
        # WHAT -- a success with no record, which is the crashed-verifier class
        # applied to the one answer the reverse stream is built from.
        if [ -z "${WORLD_SNAP_MUTE:-}" ]; then
            printf 'assist\tsnapshot\t%s\t%s\n' "${WORLD_IDS}" "${WORLD_FINAL}"
        fi
        echo "failback-assist: snapshotted"
        exit 0
        ;;
    *"failback-assist "*" unregister")
        echo "failback-assist: unregistered and returned its datasets to mountpoint=none"
        exit 0
        ;;
    *"failback-assist "*" release")
        echo "failback-assist: released and closed the record"
        exit 0
        ;;
    *"zfs list"*snapshot*)
        cat "${WORLD_DIR}/interim-snaps"
        exit 0
        ;;
    *"zfs send"*)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF

cat > "${SHIM}/zfs" <<'EOF'
#!/bin/sh
# The local pool, for the ONE command failback runs directly rather than
# through lib/zfs.subr: the receive. Its argv is logged, because "-F -u
# -x mountpoint -x canmount" is the wire and not a detail.
set -u
printf '%s\n' "$*" >> "${WORLD_DIR}/zfs.log"
cat > /dev/null
exit 0
EOF

cat > "${SHIM}/logger" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${WORLD_DIR}/logger.log"
exit 0
EOF

chmod 0755 "${SHIM}/ssh" "${SHIM}/zfs" "${SHIM}/logger"
PATH="${SHIM}:${PATH}"
export PATH

# --- the local pool, through the wrappers failback uses ---------------------

W_WRITTEN=0
W_MOUNTED=yes

# shellcheck disable=SC2329
#   Called by lib/failback.subr, which shellcheck checks as a separate file.
zfs_snapshots_r()
{
    printf '%s@seance-alpha-%s\n' "$1" "${T1}"
    printf '%s@seance-alpha-%s\n' "$1" "${T2}"
    printf '%s@%s\n' "$1" "${FINAL}"
}

W_SYNC=ok

# shellcheck disable=SC2329
zfs_pool_sync()
{
    printf 'sync %s\n' "$1" >> "${WORLD_DIR}/mounts.log"
    [ "${W_SYNC}" = "ok" ]
}

# shellcheck disable=SC2329
zfs_written_since()
{
    printf '%s\n' "${W_WRITTEN}"
}

# shellcheck disable=SC2329
zfs_mounted()
{
    [ "${W_MOUNTED}" = "yes" ]
}

# shellcheck disable=SC2329
zfs_unmount()
{
    printf 'unmount %s\n' "$1" >> "${WORLD_DIR}/mounts.log"
    W_MOUNTED=no
}

# shellcheck disable=SC2329
zfs_mount()
{
    printf 'mount %s\n' "$1" >> "${WORLD_DIR}/mounts.log"
    W_MOUNTED=yes
}

# shellcheck disable=SC2329
zfs_destroy_snapshot()
{
    printf 'destroy %s@%s\n' "$1" "$2" >> "${WORLD_DIR}/mounts.log"
}

# --- the configuration mirror (D-82) ----------------------------------------
#
# `zfs set mountpoint=` is where the pool learns which scratch path the restore
# chose, so `zfs mount -o ro` can put something there. That is exactly what the
# real pair does; the test only has to be told the path, and the code tells it.

W_SYSMIRROR=exists
W_SYSMIRROR_HAS_GUEST=yes
W_SYSPATH=""

# shellcheck disable=SC2329
zfs_exists()
{
    [ "${W_SYSMIRROR}" = "exists" ]
}

# shellcheck disable=SC2329
zfs_set()
{
    case "$1" in
        mountpoint=*) W_SYSPATH=${1#mountpoint=} ;;
    esac
    printf 'set %s %s\n' "$1" "$2" >> "${WORLD_DIR}/mounts.log"
}

# shellcheck disable=SC2329
zfs_mount_ro()
{
    printf 'mount-ro %s\n' "$1" >> "${WORLD_DIR}/mounts.log"

    [ "${W_SYSMIRROR_HAS_GUEST}" = "yes" ] || return 0
    [ -n "${W_SYSPATH}" ] || return 0

    mkdir -p "${W_SYSPATH}/arc01" || return 1
    printf 'name=arc01\n' > "${W_SYSPATH}/arc01/rc.conf_arc01"
}

# shellcheck disable=SC2329
zfs_inherit()
{
    printf 'inherit %s %s\n' "$1" "$2" >> "${WORLD_DIR}/mounts.log"
}

# ---------------------------------------------------------------------------
# One configuration; a fresh world per scenario
# ---------------------------------------------------------------------------

CONF=$( t_tmpdir )/seance.conf
cat > "${CONF}" <<'EOF'
cadence=900
standby_root=standby0
node_alpha_nodename=alpha
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
EOF

CONF_NO_SROOT=$( t_tmpdir )/seance-nosroot.conf
grep -v '^standby_root=' "${CONF}" > "${CONF_NO_SROOT}"

conf_load "${CONF}" || { echo "the fixture configuration did not load" >&2; exit 2; }

SEANCE_MOCK_NODE=alpha
SEANCE_MOCK_WORKDIR=$( t_tmpdir )/workdir
export SEANCE_MOCK_NODE SEANCE_MOCK_WORKDIR
mkdir -p "${SEANCE_MOCK_WORKDIR}"

# world <written-bytes> <claiming-peer|->
world()
{
    WORLD_DIR=$( t_tmpdir )
    export WORLD_DIR

    WORLD_IDS=${INTERIM_DS}
    WORLD_FINAL=${FINAL}
    export WORLD_IDS WORLD_FINAL

    WORLD_SSH_ALIVE="bravo-mgmt.example.net"
    WORLD_SSH_DEAF_AFTER=""
    WORLD_SNAP_MUTE=""
    export WORLD_SSH_ALIVE WORLD_SSH_DEAF_AFTER WORLD_SNAP_MUTE

    SEANCE_STATE_DIR="${WORLD_DIR}/state"
    export SEANCE_STATE_DIR
    mkdir -p "${SEANCE_STATE_DIR}"

    SEANCE_MOCK_LOG="${WORLD_DIR}/mock.log"
    SEANCE_MOCK_SCRIPT="${WORLD_DIR}/mock.script"
    export SEANCE_MOCK_LOG SEANCE_MOCK_SCRIPT
    : > "${SEANCE_MOCK_LOG}"

    # arc01 is held in the mock's world, which is the state a failback starts
    # from; what the fixture has to say is that it comes back up afterwards.
    printf 'adapter_guest_running arc01\tok\t1\n' > "${SEANCE_MOCK_SCRIPT}"

    {
        printf '%s@seance-alpha-%s\n' "${INTERIM_DS}" "${T2}"
        printf '%s@%s\n' "${INTERIM_DS}" "${FINAL}"
    } > "${WORLD_DIR}/interim-snaps"

    if [ "$2" != "-" ]; then
        printf 'placement\tarc01\talpha\n' > "${WORLD_DIR}/claims.$2-mgmt.example.net"
    fi

    W_WRITTEN=$1
    W_MOUNTED=yes
    W_SYSMIRROR=exists
    W_SYSMIRROR_HAS_GUEST=yes
    W_SYSPATH=""
    W_SYNC=ok
}

FB_OUT=""
FB_RC=0

failback()
{
    FB_OUT="${WORLD_DIR}/out"
    failback_run arc01 "$1" > "${FB_OUT}" 2>&1
    FB_RC=$?
}

t_plan 54

# ---------------------------------------------------------------------------
# THE REFUSAL
# ---------------------------------------------------------------------------

world 1441792 bravo
failback 0

t_is "${FB_RC}" "1" "failback refuses while the origin has writes the receive would destroy"
t_like "$( cat "${FB_OUT}" )" '^failback: REFUSED -- 1441792 byte\(s\) have been written here' \
    "and it prints the byte count, not an adjective"
t_like "$( cat "${FB_OUT}" )" 'seance failback arc01 --discard-origin-writes' \
    "and names the flag that accepts the loss"
t_unlike "$( cat "${WORLD_DIR}/zfs.log" 2>/dev/null || echo none )" 'recv' \
    "and NOTHING was received: the refusal happens before the destructive step"

# THE REFUSAL COSTS NOTHING. The measurement is about the ORIGIN's datasets and
# the base is a snapshot the interim already has, so neither needs the guest
# stopped -- and a guard whose refusal costs an outage is a guard people learn
# to route around.
t_unlike "$( cat "${WORLD_DIR}/ssh.log" )" 'failback-assist arc01 stop' \
    "and the guest was NOT stopped: a refusal costs no outage"

# ---------------------------------------------------------------------------
# The same refusal, from the other side of the pre-flight
#
# The pre-flight derives the interim's replica root the way repl derives where
# it sends. A fleet with no standby_root configured cannot derive it, so the
# guard runs after the final snapshot instead -- later, but never skipped.
# ---------------------------------------------------------------------------

conf_load "${CONF_NO_SROOT}" || t_diag "the no-standby_root configuration did not load"

world 1441792 bravo
failback 0

t_is "${FB_RC}" "1" \
    "with no standby root to derive from, the guard still refuses -- after the snapshot rather than before it"
t_like "$( cat "${WORLD_DIR}/ssh.log" )" 'failback-assist arc01 stop' \
    "that later refusal did stop the guest, which is the cost of not being able to pre-flight"
t_like "$( cat "${FB_OUT}" )" 'seance failback-assist arc01 start' \
    "so the refusal names the command that puts it back"
t_unlike "$( cat "${WORLD_DIR}/ssh.log" )" 'failback-assist arc01 unregister' \
    "and the interim was NOT unregistered: it still has the only copy"

conf_load "${CONF}" || t_diag "the fixture configuration did not reload"

# ---------------------------------------------------------------------------
# THE DELIBERATE LOSS
# ---------------------------------------------------------------------------

world 1441792 bravo
failback 1

t_is "${FB_RC}" "0" "--discard-origin-writes completes the failback"
t_like "$( cat "${FB_OUT}" )" '^failback: discarding 1441792 byte\(s\)' \
    "and says how much it discarded"
t_like "$( cat "${FB_OUT}" )" '^failback: arc01 is home on alpha and running' \
    "and ends in one verdict line"

t_like "$( cat "${SEANCE_STATE_DIR}/succession.log" )" \
    "^arc01${TAB}bravo${TAB}alpha${TAB}[0-9]{8}T[0-9]{6}Z${TAB}discard:1441792\$" \
    "the record carries the byte count, so the decision outlives the terminal it was typed in"

# --- the wire ---------------------------------------------------------------

t_like "$( cat "${WORLD_DIR}/zfs.log" )" \
    "^recv -F -u -x mountpoint -x canmount ${ORIGIN_DS}\$" \
    "the receive is -F -u -x mountpoint -x canmount, and lands in the LIVE dataset"
t_like "$( cat "${WORLD_DIR}/ssh.log" )" \
    "^zfs send -p -I '@${BASE}' '${INTERIM_DS}@${FINAL}'\$" \
    "and the send is an incremental from the newest snapshot the two ends had in common"

# --- the order, which is the whole safety of it -----------------------------

t_is "$( grep -o 'failback-assist arc01 [a-z]*' "${WORLD_DIR}/ssh.log" | tr '\n' ' ' )" \
    "failback-assist arc01 stop failback-assist arc01 snapshot failback-assist arc01 unregister failback-assist arc01 release " \
    "the interim is asked in order: stop, snapshot, unregister, release"

t_is "$( grep -E "^(unmount|mount) ${ORIGIN_DS}\$" "${WORLD_DIR}/mounts.log" )" \
    "unmount ${ORIGIN_DS}
mount ${ORIGIN_DS}" \
    "the origin's dataset is unmounted around the receive and mounted again after"

# --- the configuration came home too (D-82) ---------------------------------
t_like "$( cat "${FB_OUT}" )" '^  restored arc01 configuration from bravo' \
    "the interim's copy of the guest's configuration is restored on the way home"
t_like "$( cat "${WORLD_DIR}/mounts.log" )" "^mount-ro standby0/bravo/seance-sys\$" \
    "the mirror is mounted READ-ONLY: this node is reading another node's record"
t_like "$( cat "${WORLD_DIR}/mounts.log" )" '^inherit mountpoint standby0/bravo/seance-sys$' \
    "and it is put back to where it was afterwards"

# A mirror that is not there is a note, not a failure: this node still has the
# copy of the configuration it had before it died, and refusing a completed
# data transfer over it would be the wrong trade at the wrong moment.
world 0 bravo
W_SYSMIRROR=absent
failback 1
t_is "${FB_RC}" "0" "a failback still completes when the interim's configuration mirror is absent"
t_like "$( cat "${FB_OUT}" )" 'configuration was NOT restored from bravo' \
    "and it says so rather than passing over it in silence"

# ---------------------------------------------------------------------------
# The measurement is only true after the pool has committed
#
# `written@` is exact only once a transaction group is out; a write made
# seconds ago is not in it yet. Observed in the guest: 1 MiB read as 0 bytes
# until `zpool sync`. A guard that measured the first number would report
# "nothing to lose" and then destroy the megabyte.
# ---------------------------------------------------------------------------

world 1441792 bravo
failback 1
t_like "$( cat "${WORLD_DIR}/mounts.log" )" "^sync ${ORIGIN_DS}\$" \
    "the pool is committed before written@ is read"
t_is "$( grep -c "^sync " "${WORLD_DIR}/mounts.log" )" "2" \
    "once for the pre-flight and once for the measurement that goes on the record"

world 1441792 bravo
W_SYNC=fail
failback 1
t_is "${FB_RC}" "1" \
    "a pool that will not commit refuses the failback, even with --discard-origin-writes"
t_like "$( cat "${FB_OUT}" )" 'written@ cannot be' \
    "and says why: an untrustworthy byte count reads as nothing to lose"
t_unlike "$( cat "${WORLD_DIR}/zfs.log" 2>/dev/null || echo none )" 'recv' \
    "and nothing was received"

# ---------------------------------------------------------------------------
# The refusals that are not about bytes
# ---------------------------------------------------------------------------

world 0 -
failback 0
t_is "${FB_RC}" "1" "failback refuses when no living peer claims the guest"
t_like "$( cat "${FB_OUT}" )" 'no living peer claims arc01' \
    "and says so, because 'already home' and 'the peer is not answering' look the same from here"

world 0 bravo
WORLD_SSH_ALIVE=""
export WORLD_SSH_ALIVE
failback 0
t_is "${FB_RC}" "1" "a failback from a peer that cannot be reached is not a failback"

# A guest that is neither held nor stopped here: web01 in the mock's world is
# running and unheld, which is exactly the state that must be refused.
world 0 bravo
printf 'adapter_guest_running web01\tok\t1\n' > "${SEANCE_MOCK_SCRIPT}"
WEB_OUT="${WORLD_DIR}/web.out"
failback_run web01 0 > "${WEB_OUT}" 2>&1
WEB_RC=$?
t_is "${WEB_RC}" "1" "failback refuses a guest that is running and unheld here"
t_like "$( cat "${WEB_OUT}" )" 'neither held nor stopped here' \
    "and says which of the two preconditions it failed"
t_unlike "$( cat "${WORLD_DIR}/ssh.log" 2>/dev/null )" 'failback-assist web01' \
    "and it never touched the interim"

# ---------------------------------------------------------------------------
# THE INTERIM GOES AWAY IN THE MIDDLE
#
# The dangerous window is between "the guest is stopped there" and "the data is
# here": the guest is down, the origin has not received anything, and whatever
# the operator does next they have to be told what state they are in. A
# failback that dies here must leave the origin untouched and must name the one
# command that puts the guest back up on the interim.
# ---------------------------------------------------------------------------

world 0 bravo
WORLD_SSH_DEAF_AFTER=snapshot
export WORLD_SSH_DEAF_AFTER
failback 0

t_is "${FB_RC}" "1" "an interim that goes away after the final snapshot fails the failback"
t_like "$( tail -1 "${FB_OUT}" )" '^failback: FAIL'     "and the last line is a verdict, not the last thing that happened to work"
t_like "$( cat "${FB_OUT}" )" 'seance failback-assist arc01 start'     "and the way back is a command an operator can type, not a description of one"

t_unlike "$( cat "${WORLD_DIR}/zfs.log" 2>/dev/null || echo none )" 'recv'     "nothing was received: the origin's live dataset is untouched"
t_unlike "$( cat "${WORLD_DIR}/mounts.log" 2>/dev/null || echo none )" '^unmount '     "and nothing was unmounted for a receive that never came"
t_unlike "$( cat "${SEANCE_MOCK_LOG}" )" 'adapter_guest_release'     "the guest is NOT released here: half a failback is not a failback"
t_unlike "$( cat "${SEANCE_MOCK_LOG}" )" 'adapter_guest_start'     "and it is NOT started here, which is the sentence that would have meant two writers"
t_is "$( cat "${SEANCE_STATE_DIR}/succession.log" 2>/dev/null || printf '' )" ""     "and no succession record is written for a failback that did not happen"
t_is "$( grep -o 'failback-assist arc01 [a-z]*' "${WORLD_DIR}/ssh.log" | tr '\n' ' ' )"     "failback-assist arc01 stop failback-assist arc01 snapshot "     "the interim was asked to stop and to snapshot, and was never asked to unregister"

# The same cut one step earlier: the guest is stopped and the snapshot never
# happens. The verdict has to name the step, because "it failed" and "it failed
# after stopping your guest" are different instructions to a human at 03:00.
world 0 bravo
WORLD_SSH_DEAF_AFTER=stop
export WORLD_SSH_DEAF_AFTER
failback 0

t_is "${FB_RC}" "1" "an interim that goes away after the stop fails the failback too"
t_like "$( cat "${FB_OUT}" )" 'could not take the final snapshot of arc01'     "and names the step that did not happen"
t_like "$( cat "${FB_OUT}" )" 'seance failback-assist arc01 start'     "and still prints the way back, because the guest is down either way"

# ---------------------------------------------------------------------------
# THE INTERIM SAYS IT SNAPSHOTTED AND DOES NOT SAY WHAT
#
# Success with no record. Everything after step 2 is built on the name the
# interim returns -- the reverse stream is `zfs send -I @base <root>@<final>`
# -- so a caller that read the silence as "fine" would send from a name it had
# guessed. The crashed-verifier class (TESTING.md §5) at the one seam a
# failback cannot do without.
# ---------------------------------------------------------------------------

world 0 bravo
WORLD_SNAP_MUTE=1
export WORLD_SNAP_MUTE
failback 0

t_is "${FB_RC}" "1" \
    "an interim that reports a snapshot without saying which one fails the failback"
t_like "$( cat "${FB_OUT}" )" 'did not say what: empty output with a success status is a contract violation' \
    "and says so in those words, rather than proceeding on a name nobody returned"
t_unlike "$( cat "${WORLD_DIR}/zfs.log" 2>/dev/null || echo none )" 'recv' \
    "and nothing was received"

# ---------------------------------------------------------------------------
# TWICE
#
# A failback is typed by a human, and a human who is not sure it worked types
# it again. The second one must refuse -- the interim has stopped claiming the
# guest, which is exactly the state that means "already home" -- and it must
# not touch the guest that is now running here.
# ---------------------------------------------------------------------------

world 0 bravo
failback 1
FIRST_RC=${FB_RC}
FIRST_DIR=${WORLD_DIR}
t_is "${FIRST_RC}" "0" "the first failback completes"

# The interim released its claim as step 6 of that run, so it no longer answers
# `seance placement` with one.
rm -f "${FIRST_DIR}/claims.bravo-mgmt.example.net"
: > "${SEANCE_MOCK_LOG}"
SECOND_OUT="${FIRST_DIR}/second.out"
failback_run arc01 1 > "${SECOND_OUT}" 2>&1
SECOND_RC=$?

t_is "${SECOND_RC}" "1" "the second failback of the same guest refuses"
t_like "$( cat "${SECOND_OUT}" )" 'no living peer claims arc01'     "and says the guest is claimed by nobody, which is what home looks like"
t_unlike "$( cat "${SEANCE_MOCK_LOG}" )" 'adapter_guest_stop'     "and it does not stop the guest it just brought home"

# A guest this node does not have at all is not a failback, it is a promotion.
world 0 bravo
GONE_OUT="${WORLD_DIR}/gone.out"
failback_run nosuchguest 0 > "${GONE_OUT}" 2>&1
GONE_RC=$?
t_is "${GONE_RC}" "1" "failback refuses a guest this node does not know"
t_like "$( cat "${GONE_OUT}" )" 'failback returns a guest to a home that still knows it' \
    "and says why that is a different operation"

t_done
