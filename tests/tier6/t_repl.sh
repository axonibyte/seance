#!/bin/sh
# Tier 6, stage 'repl' -- the replication engine against a real pseudo-cluster.
#
# Three vnet jails, real ZFS, real ssh, real sends. seance's own verbs are what
# runs: nothing here reimplements the engine or reaches around it. What is
# asserted is what a survivor would need to be true on the morning after:
#
#   * a replica exists on every heir, carrying the lineage's names;
#   * THE SHADOW-MOUNT LAW: no replica dataset carries a mountpoint of its own,
#     and none of them may mount by accident. This is the August defect, and it
#     is asserted from the peer's own 'zfs get -o value,source' rather than
#     inferred from the command line that was supposed to prevent it;
#   * the standby parents stay hidden;
#   * a second tick sends an increment, not another copy;
#   * retention prunes both ends identically, never the incremental base, and
#     never a snapshot that is not seance's;
#   * status and verify agree with the disks;
#   * and a node whose configuration has drifted is named LOUDLY, with an exit
#     code, because seance never propagates that file.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/stage.subr
. "${T_ROOT}/tests/cluster/lib/stage.subr"

stage_begin repl

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/fence.subr
. "${T_ROOT}/tests/cluster/lib/fence.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the repl stage builds jails and ZFS datasets; it needs root"
    echo "t_repl: must run as root" >&2
    exit 2
fi

t_plan 87

TAB=$( printf '\t.' )
TAB=${TAB%.}

# ---------------------------------------------------------------------------
# Driving seance inside a node
# ---------------------------------------------------------------------------

SN_ADAPTER="/usr/local/seance/tests/cluster/adapter-pseudo.subr"
SN_ENV="SEANCE_CONF=/etc/seance.conf SEANCE_STATE_DIR=/var/db/seance SEANCE_RUN_DIR=/var/run/seance SEANCE_ADAPTER=${SN_ADAPTER}"
SN_BIN="/usr/local/seance/bin/seance"

# node_seance <node> <args...>  -- run a seance verb inside a node.
#
# </dev/null because the verbs start ssh, and a caller inside a read loop would
# otherwise lose its input to it (D-24).
#
# shellcheck disable=SC2329
#   Invoked indirectly by t_rc, which runs the command that follows its '--'.
node_seance()
{
    local _n

    _n=$1
    shift

    # shellcheck disable=SC2086
    #   Deliberate word splitting: ${SN_ENV} is a list of VAR=value words for
    #   env(1), each of which must arrive as its own argument.
    cluster_exec "${_n}" env ${SN_ENV} "${SN_BIN}" "$@" < /dev/null
}

# node_sh <node> <shell-command...>  -- one command inside a node, with the
# seance environment set, for the fixture work the adapter owns.
node_sh()
{
    local _n

    _n=$1
    shift

    # shellcheck disable=SC2086
    #   Deliberate word splitting, as above.
    cluster_exec "${_n}" env ${SN_ENV} sh -c "$*" < /dev/null
}

# nz <node> <zfs args...>  -- zfs inside a node, stdin closed.
nz()
{
    local _n

    _n=$1
    shift

    cluster_exec "${_n}" zfs "$@" < /dev/null
}

# guest_create <node> <guest> <type> <home>
guest_create()
{
    node_sh "$1" ". ${SN_ADAPTER}; adapter_init && pseudo_guest_create $2 $3 $4"
}

# ---------------------------------------------------------------------------
# Bring the cluster up and configure it
# ---------------------------------------------------------------------------

cluster_up 3 || { t_diag "cluster_up failed"; t_done; }

# The fence driver, because `verify` now asks every peer it may have to fence
# whether it answers (D-186), and a world without one is an incomplete fleet
# rather than a passing one -- the same reasoning as the boot gate above.
fence_install || { t_diag "fence_install failed"; t_done; }
t_at_exit 'fence_uninstall'

BASE_DS=$( cluster_base_dataset )
ALPHA_DS=$( cluster_dataset alpha )
BRAVO_DS=$( cluster_dataset bravo )

# One configuration file, byte-identical on every node -- which is the very
# invariant `verify` exists to enforce. The per-node standby root is expressed
# with the %n substitution (D-59) rather than by giving each node a different
# file, because a different file is exactly what the check is looking for.
CONF=$( t_tmpdir )/seance.conf
cat > "${CONF}" <<EOF
cadence=60
retention_recent=14400
retention_hourly=172800
skew_tolerance=120
ssh_user=root
ssh_port=22
ssh_extra_opts=-i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
standby_root=${BASE_DS}/%n/standby

node_alpha_nodename=alpha
node_alpha_fence_driver=jail
node_alpha_fence_target=alpha
node_alpha_mgmt=$( cluster_ip alpha )
node_alpha_heir=bravo
node_alpha_heir2=charlie

node_bravo_nodename=bravo
node_bravo_fence_driver=jail
node_bravo_fence_target=bravo
node_bravo_mgmt=$( cluster_ip bravo )
node_bravo_heir=charlie
node_bravo_heir2=alpha

node_charlie_nodename=charlie
node_charlie_fence_driver=jail
node_charlie_fence_target=charlie
node_charlie_mgmt=$( cluster_ip charlie )
node_charlie_heir=alpha
node_charlie_heir2=bravo

guest_arc01_heir=bravo
EOF

for n in alpha bravo charlie; do
    cp "${CONF}" "$( cluster_root "${n}" )/etc/seance.conf"
    mkdir -p "$( cluster_root "${n}" )/usr/local/etc/cron.d"
    # The boot gate, because these worlds assert that `verify` passes CLEANLY:
    # a node with no gate is a node whose estate nothing withholds after a
    # promotion, and verify says so (D-183). Installing it here keeps the
    # clean-run assertions about what they were written to be about.
    mkdir -p "$( cluster_root "${n}" )/usr/local/etc/rc.d"
    cp "${T_ROOT}/rc.d/seance_gate" "$( cluster_root "${n}" )/usr/local/etc/rc.d/seance_gate"
    chmod 0555 "$( cluster_root "${n}" )/usr/local/etc/rc.d/seance_gate"
    printf 'seance_gate_enable="YES"\n' >> "$( cluster_root "${n}" )/etc/rc.conf"
done

t_rc 0 "the fleet configuration validates on alpha" \
    -- node_seance alpha config --check

# ---------------------------------------------------------------------------
# A world: two guests at home, plus one with a per-guest heir override
# ---------------------------------------------------------------------------

guest_create alpha web01 jail alpha || t_diag "creating web01 failed"
guest_create bravo db01 bhyve bravo || t_diag "creating db01 failed"
guest_create alpha arc01 jail alpha || t_diag "creating arc01 failed"

# A child dataset per guest, so that the recursive snapshot has something to be
# recursive about, and a file in each so that a promotion would have something
# to promote.
nz alpha create "${ALPHA_DS}/web01/data" || t_diag "web01's child dataset"
nz bravo create "${BRAVO_DS}/db01/data" || t_diag "db01's child dataset"

cluster_exec alpha sh -c 'echo web01-root-v1 > /seance/web01/marker' < /dev/null
cluster_exec alpha sh -c 'echo web01-child-v1 > /seance/web01/data/marker' < /dev/null
cluster_exec bravo sh -c 'echo db01-root-v1 > /seance/db01/marker' < /dev/null
cluster_exec bravo sh -c 'echo db01-child-v1 > /seance/db01/data/marker' < /dev/null

# The precondition without which the shadow-mount law means nothing: the SOURCE
# dataset must carry a mountpoint of its own, as a CBSD guest's does
# (sudoexec/mkdatadir:14-23). An inherited mountpoint is never put into the
# stream by 'zfs send -p', so a test built on one would pass with -x mountpoint
# removed, and would be measuring nothing at all.
t_is "$( nz alpha get -H -o source mountpoint "${ALPHA_DS}/web01" )" "local" \
    "the source guest dataset carries a LOCAL mountpoint (the law has something to bite)"

# ---------------------------------------------------------------------------
# Tick one
# ---------------------------------------------------------------------------

TICK1_OUT=$( node_seance alpha repl --now 2>&1 )
TICK1_RC=$?
t_is "${TICK1_RC}" "0" "repl tick 1 on alpha"

# The receive must place the properties correctly the FIRST time. seance also
# holds the shadow-mount law on every tick and repairs drift, which is right --
# but it means the property assertions further down would pass even with the
# receive flags wrong, because the repair would have covered for them. This is
# what keeps '-x mountpoint' load-bearing: a tick that had to undo its own
# receive says "repaired", and a first tick must only ever say "enforced"
# (canmount, which cannot be inherited and so arrives at its default).
t_unlike "${TICK1_OUT}" 'repaired' \
    "the first receive got the properties right by itself: nothing was repaired"

t_rc 0 "repl tick 1 on bravo" -- node_seance bravo repl --now

# replica_root <peer> <home> <guest>
replica_root()
{
    printf '%s/standby/%s/%s\n' "$( cluster_dataset "$1" )" "$2" "$3"
}

WEB_ON_BRAVO=$( replica_root bravo alpha web01 )
WEB_ON_CHARLIE=$( replica_root charlie alpha web01 )
DB_ON_CHARLIE=$( replica_root charlie bravo db01 )
DB_ON_ALPHA=$( replica_root alpha bravo db01 )
ARC_ON_BRAVO=$( replica_root bravo alpha arc01 )

t_rc 0 "web01's replica exists on bravo" -- nz bravo list -H -o name "${WEB_ON_BRAVO}"
t_rc 0 "web01's child dataset came with it" \
    -- nz bravo list -H -o name "${WEB_ON_BRAVO}/data"
t_rc 0 "web01's replica exists on charlie, the second heir" \
    -- nz charlie list -H -o name "${WEB_ON_CHARLIE}"
t_rc 0 "db01's replica exists on charlie" -- nz charlie list -H -o name "${DB_ON_CHARLIE}"
t_rc 0 "db01's replica exists on alpha" -- nz alpha list -H -o name "${DB_ON_ALPHA}"

# arc01 named its own heir, so it must be on bravo and NOWHERE else: a
# per-guest override replaces the node's succession entirely (D-29).
t_rc 0 "arc01's replica exists on bravo, its only configured heir" \
    -- nz bravo list -H -o name "${ARC_ON_BRAVO}"
t_rc 1 "arc01 has no replica on charlie: the override replaced the order, it did not extend it" \
    -- nz charlie list -H -o name "$( replica_root charlie alpha arc01 )"

# --- the shadow-mount law ---------------------------------------------------
#
# Asserted on the peer, from ZFS's own account of value AND source. A value of
# 'none' whose source is 'local' or 'received' is a replica carrying its own
# mountpoint; what the law requires is that it carries none of its own at all.
law_violations()
{
    local _node _root _list _d _mp _ms _cm

    _node=$1
    _root=$2

    _list=$( nz "${_node}" list -H -o name -t filesystem,volume -r "${_root}" )

    for _d in ${_list}; do
        _mp=$( nz "${_node}" get -H -o value mountpoint "${_d}" )
        _ms=$( nz "${_node}" get -H -o source mountpoint "${_d}" )
        _cm=$( nz "${_node}" get -H -o value canmount "${_d}" )

        [ "${_mp}" = "none" ] || printf '%s mountpoint=%s\n' "${_d}" "${_mp}"
        case "${_ms}" in
            local|received) printf '%s mountpoint-source=%s\n' "${_d}" "${_ms}" ;;
        esac
        [ "${_cm}" = "noauto" ] || printf '%s canmount=%s\n' "${_d}" "${_cm}"
    done
}

t_is "$( law_violations bravo "${WEB_ON_BRAVO}" )" "" \
    "every dataset of web01's replica on bravo obeys the shadow-mount law"
t_is "$( law_violations charlie "${WEB_ON_CHARLIE}" )" "" \
    "every dataset of web01's replica on charlie obeys the shadow-mount law"
t_is "$( law_violations charlie "${DB_ON_CHARLIE}" )" "" \
    "every dataset of db01's replica on charlie obeys the shadow-mount law"

# The negative half of the same assertion: the live guest's mountpoint must not
# have travelled with the stream.
t_unlike "$( nz bravo get -H -o value mountpoint "${WEB_ON_BRAVO}" )" \
    '^/seance/web01$' \
    "the replica did not inherit the live guest's own mountpoint"

# --- the replica's identity (D-183) -----------------------------------------
#
# The tick that maintains a replica also records WHICH GUEST it is a replica
# of, because the replica's dataset name comes from the source dataset's
# basename and cannot be read backwards. Asserted here, on the sending side's
# own work, because promote's ability to name a guest at 03:00 is entirely this
# line having run at some quiet moment beforehand.
t_is "$( nz bravo get -H -o value seance:guest "${WEB_ON_BRAVO}" )" "web01" \
    "the replica records the guest it belongs to"
t_is "$( nz charlie get -H -o value seance:guest "${WEB_ON_CHARLIE}" )" "web01" \
    "on every heir, not only the first"


# --- the standby parents ----------------------------------------------------
for pair in "bravo ${BASE_DS}/bravo/standby" \
            "bravo ${BASE_DS}/bravo/standby/alpha" \
            "charlie ${BASE_DS}/charlie/standby" \
            "charlie ${BASE_DS}/charlie/standby/alpha"; do
    node=${pair%% *}
    ds=${pair#* }
    t_is "$( nz "${node}" get -H -o value canmount,mountpoint "${ds}" | tr '\n' ' ' )" \
        "noauto none " \
        "standby parent ${node}:${ds} is canmount=noauto mountpoint=none"
done

# --- the snapshots, and the lag record --------------------------------------
SNAP1=$( nz bravo list -H -o name -t snapshot "${WEB_ON_BRAVO}" | sed -n '$s/.*@//p' )
t_like "${SNAP1}" '^seance-alpha-[0-9]{8}T[0-9]{6}Z$' \
    "the replica's snapshot carries the wire-protocol name"

LAG=$( cluster_exec alpha cat /var/db/seance/lag/web01.bravo < /dev/null )
t_is "${LAG% * *}" "${SNAP1#seance-alpha-}" \
    "alpha's lag record for web01@bravo names the snapshot bravo actually has"
t_is "${LAG##* }" "0" "the lag record's exit status is 0"

# --- the configuration mirror (D-82) ----------------------------------------
#
# A jail's registerable configuration lives outside its own dataset on real
# CBSD, so `repl` carries it in one extra dataset per node and replicates that
# dataset exactly like a guest. The pseudo-cluster's guests keep their
# configuration in a child dataset and so never need the mirror -- which is
# precisely why the DATASET is asserted here rather than its contents: what
# tier 6 can prove is that the mirror is made, named with the tick's own
# lineage, sent to the same heirs, and hidden on arrival like every other
# replica. That a real jail then promotes out of it is a shape-B assertion
# (tests/tier5/README).

SYS_ON_ALPHA="${ALPHA_DS}/seance-sys"
SYS_ON_BRAVO=$( replica_root bravo alpha seance-sys )

t_rc 0 "the configuration mirror dataset exists on alpha" \
    -- nz alpha list -H -o name "${SYS_ON_ALPHA}"
t_is "$( nz alpha get -H -o value mountpoint "${SYS_ON_ALPHA}" )" \
    "/var/db/seance/sys" \
    "and it is mounted inside seance's own state directory, not in CBSD's"

t_is "$( nz alpha list -H -o name -t snapshot "${SYS_ON_ALPHA}" | sed -n '$s/.*@//p' )" \
    "${SNAP1}" \
    "it is snapshotted with the TICK's name, so its lineage is the fleet's lineage"

t_rc 0 "and its replica landed under the standby tree on bravo" \
    -- nz bravo list -H -o name "${SYS_ON_BRAVO}"
t_is "$( law_violations bravo "${SYS_ON_BRAVO}" )" "" \
    "the mirror's replica obeys the shadow-mount law like any other replica"


# ---------------------------------------------------------------------------
# Tick two: an increment, not a second copy
# ---------------------------------------------------------------------------

cluster_exec alpha sh -c 'echo web01-root-v2 >> /seance/web01/marker' < /dev/null
cluster_exec alpha sh -c 'echo web01-child-v2 >> /seance/web01/data/marker' < /dev/null

# A foreign tool's snapshot, planted on the replica before the tick. seance
# must send straight through it and must never destroy it: a snapshot whose
# name seance does not recognise belongs to somebody else.
nz bravo snapshot "${WEB_ON_BRAVO}@zrepl-20200101T000000" ||
    t_diag "planting the foreign snapshot failed"

TICK2_OUT=$( node_seance alpha repl --now 2>&1 )
TICK2_RC=$?
t_is "${TICK2_RC}" "0" "repl tick 2 on alpha"

# The receive is expected to place the properties correctly the FIRST time.
# seance also holds the law every tick and repairs drift, which is right -- but
# it means the property assertions below would pass even if the receive flags
# were wrong, because the repair would have covered for them. This assertion is
# what keeps '-x mountpoint' load-bearing: a tick with nothing to repair says
# nothing, and a tick that had to undo its own receive says "repaired".
t_unlike "${TICK2_OUT}" 'repaired' \
    "a clean tick repairs nothing: the receive got the properties right by itself"

SNAPS_AFTER=$( nz bravo list -H -o name -t snapshot "${WEB_ON_BRAVO}" |
    sed 's/.*@//' | sort | tr '\n' ' ' )
SNAP2=$( printf '%s\n' "${SNAPS_AFTER}" | tr ' ' '\n' |
    grep '^seance-alpha-' | sort | tail -1 )

t_isnt "${SNAP2}" "${SNAP1}" "tick 2 put a newer snapshot on the replica"
t_like "${SNAPS_AFTER}" "${SNAP1}" \
    "tick 2 left tick 1's snapshot in place: the lineage is a chain, not a replacement"
t_like "${SNAPS_AFTER}" 'zrepl-20200101T000000' \
    "the foreign snapshot on the replica survived a tick untouched"

# --- the replica's content, and the repair of a hand-mount ------------------
#
# Reading it means mounting it, which is what a promotion does and what nothing
# else may do. The probe deliberately leaves the mountpoint and canmount it set
# behind, so that the next tick has drift to repair -- that repair is the one
# seance is allowed to perform, and it says so in its log.
t_stdout_is "web01-root-v1
web01-root-v2" "the replica's data is the source's data, child datasets and all" \
    -- node_sh bravo "mkdir -p /tmp/probe &&
        zfs set mountpoint=/tmp/probe ${WEB_ON_BRAVO} &&
        zfs mount ${WEB_ON_BRAVO} &&
        cat /tmp/probe/marker &&
        zfs umount ${WEB_ON_BRAVO}"

t_stdout_is "web01-child-v1
web01-child-v2" "and the child dataset's data came with it" \
    -- node_sh bravo "zfs mount ${WEB_ON_BRAVO} &&
        zfs mount ${WEB_ON_BRAVO}/data &&
        cat /tmp/probe/data/marker &&
        zfs umount ${WEB_ON_BRAVO}/data &&
        zfs umount ${WEB_ON_BRAVO}"

nz bravo set canmount=on "${WEB_ON_BRAVO}"

t_isnt "$( law_violations bravo "${WEB_ON_BRAVO}" )" "" \
    "the hand-mount left the replica in breach of the law (the fixture is real)"

node_seance alpha repl --now > /dev/null 2>&1

t_is "$( law_violations bravo "${WEB_ON_BRAVO}" )" "" \
    "a tick repaired the mountpoint and canmount the hand-mount left behind"

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

t_rc 0 "status on alpha exits 0: every replica fresh, the mesh agrees" \
    -- node_seance alpha status
t_rc 0 "status on bravo exits 0" -- node_seance bravo status
t_rc 0 "status on charlie exits 0 with no guests of its own" \
    -- node_seance charlie status

STATUS_TSV=$( node_seance alpha status --tsv )
t_like "${STATUS_TSV}" "^guest${TAB}web01${TAB}jail${TAB}alpha${TAB}yes${TAB}no\$" \
    "status --tsv reports web01 as a running, unheld jail at home on alpha"
t_like "${STATUS_TSV}" \
    "^replica${TAB}web01${TAB}bravo${TAB}[0-9]{8}T[0-9]{6}Z${TAB}[0-9]+${TAB}fresh${TAB}0" \
    "status --tsv reports web01's replica on bravo as fresh"
t_like "${STATUS_TSV}" "^carp${TAB}not-configured\$" \
    "status says CARP is not configured rather than inventing a vhid map"

# ---------------------------------------------------------------------------
# A tick that fails must move the record on
#
# Otherwise `status` goes on reporting the last successful tick and exiting 0
# while replication is broken -- the quiet failure this whole project is a
# reaction to. The record keeps the timestamp the peer was last known to hold,
# because that is still true and its age is what will eventually call it stale;
# what changes is the tick epoch and the exit status.
# ---------------------------------------------------------------------------

PREV_TS=$( printf '%s\n' "${STATUS_TSV}" |
    awk -F "${TAB}" '$1 == "replica" && $2 == "web01" && $3 == "charlie" { print $4 }' )
t_like "${PREV_TS}" '^[0-9]{8}T[0-9]{6}Z$' \
    "web01's replica on charlie has a known timestamp to lose"

cluster_isolate charlie || t_diag "cluster_isolate charlie failed"

node_seance alpha repl --guest web01 --peer charlie --now > /dev/null 2>&1
FAILED_RC=$?
t_isnt "${FAILED_RC}" "0" "a tick to an unreachable peer reports failure"

FAILED_TSV=$( node_seance alpha status --tsv 2>&1 )
t_like "${FAILED_TSV}" \
    "^replica${TAB}web01${TAB}charlie${TAB}${PREV_TS}${TAB}[0-9]+${TAB}fresh${TAB}1" \
    "the lag record moved on with rc 1 and KEPT what charlie was last known to hold"

cluster_heal charlie || t_diag "cluster_heal charlie failed"

t_rc 0 "charlie answers again after the heal" \
    -- cluster_exec alpha ping -c 1 -t 5 "$( cluster_ip charlie )"
t_rc 0 "and the next tick puts the pair back" \
    -- node_seance alpha repl --guest web01 --peer charlie --now

# A filter that matches nothing is a contract error. The alternative is a
# mistyped --guest printing "0 guests x 0 pairs, 0 ok, 0 failed" and exiting 0.
t_rc 2 "repl --guest naming a guest that is not here is a contract error" \
    -- node_seance alpha repl --guest nosuchguest --now
t_rc 2 "repl --peer naming a node nothing replicates to is a contract error" \
    -- node_seance alpha repl --guest web01 --peer alpha --now

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

CRON=$( node_seance alpha verify --render cron )
t_like "${CRON}" '^\*/1 \* \* \* \* root /usr/local/bin/seance repl$' \
    "verify --render cron renders a crontab(5) system line at the shortest cadence"

t_rc 2 "verify --render of a subject it does not know is a contract error" \
    -- node_seance alpha verify --render nonsense

# Nothing installed yet: verify must say so, and must NOT install it itself.
VERIFY_BEFORE=$( node_seance alpha verify 2>&1 )
VERIFY_RC_BEFORE=$?
t_like "${VERIFY_BEFORE}" '^WARN cron: no crontab fragment' \
    "verify warns that replication is not scheduled"
t_isnt "${VERIFY_RC_BEFORE}" "0" "and says so in its exit code"
t_rc 1 "verify did not install the crontab fragment itself" \
    -- cluster_exec alpha test -e /usr/local/etc/cron.d/seance

for n in alpha bravo charlie; do
    node_seance "${n}" verify --render cron \
        > "$( cluster_root "${n}" )/usr/local/etc/cron.d/seance"
done

VERIFY=$( node_seance alpha verify 2>&1 )
VERIFY_RC=$?
t_is "${VERIFY_RC}" "0" "verify on alpha passes once everything it renders is in place"
t_unlike "${VERIFY}" '^(WARN|FAIL) ' "verify's report carries no WARN and no FAIL"
t_like "${VERIFY}" '^PASS mesh: alpha -> bravo' "the mesh matrix reaches bravo"
t_like "${VERIFY}" '^PASS mesh: alpha -> charlie' "the mesh matrix reaches charlie"
t_like "${VERIFY}" '^PASS clock: bravo is [0-9]+s away' "the pairwise clock delta is measured"
t_like "${VERIFY}" '^PASS config: bravo holds the same file' "the mesh holds one configuration"
t_like "${VERIFY}" "^PASS standby: bravo:${BASE_DS}/bravo/standby/alpha canmount=noauto mountpoint=none" \
    "verify reads the standby parents on the peer itself"
t_like "${VERIFY}" '^PASS cron: /usr/local/etc/cron.d/seance carries the expected line' \
    "verify finds the crontab fragment it rendered"

# ---------------------------------------------------------------------------
# Retention: the same ladder, both ends, and never the base
# ---------------------------------------------------------------------------

NOW=$( date -u +%s )
TS_ANCIENT=$( date -u -r $(( NOW - 5 * 86400 )) +%Y%m%dT%H%M%SZ )
HOUR=$(( ( NOW - 36000 ) / 3600 * 3600 ))
TS_MID1=$( date -u -r $(( HOUR + 300 )) +%Y%m%dT%H%M%SZ )
TS_MID2=$( date -u -r $(( HOUR + 3300 )) +%Y%m%dT%H%M%SZ )

ARC_SRC="${ALPHA_DS}/arc01"

for ts in "${TS_ANCIENT}" "${TS_MID1}" "${TS_MID2}"; do
    nz alpha snapshot -r "${ARC_SRC}@seance-alpha-${ts}" ||
        t_diag "fabricating ${ts} on the source failed"
    nz bravo snapshot -r "${ARC_ON_BRAVO}@seance-alpha-${ts}" ||
        t_diag "fabricating ${ts} on the replica failed"
done
nz bravo snapshot "${ARC_ON_BRAVO}@zrepl-19990101T000000" ||
    t_diag "planting the foreign snapshot on arc01's replica failed"

src_snaps()
{
    nz alpha list -H -o name -t snapshot -r "${ARC_SRC}" |
        sed 's/.*@//' | sort -u | tr '\n' ' '
}

rep_snaps()
{
    nz bravo list -H -o name -t snapshot -r "${ARC_ON_BRAVO}" |
        sed 's/.*@//' | sort -u | tr '\n' ' '
}

# --locked: do exactly this pair and take no new snapshot, so that the ladder
# is applied to the lineage this test built rather than to one a tick made.
t_rc 0 "a prune-only tick over arc01 -> bravo" \
    -- node_seance alpha repl --guest arc01 --peer bravo --locked

SRC_AFTER=$( src_snaps )
REP_AFTER=$( rep_snaps )

t_unlike "${SRC_AFTER}" "seance-alpha-${TS_ANCIENT}" \
    "retention pruned the five-day-old snapshot on the source"
t_unlike "${REP_AFTER}" "seance-alpha-${TS_ANCIENT}" \
    "retention pruned the five-day-old snapshot on the replica"
t_unlike "${SRC_AFTER}" "seance-alpha-${TS_MID1}" \
    "the hourly rung kept one snapshot of that hour on the source, not two"
t_unlike "${REP_AFTER}" "seance-alpha-${TS_MID1}" \
    "the hourly rung kept one snapshot of that hour on the replica, not two"
t_like "${SRC_AFTER}" "seance-alpha-${TS_MID2}" \
    "the newest snapshot of that hour survived on the source"
t_like "${REP_AFTER}" "seance-alpha-${TS_MID2}" \
    "the newest snapshot of that hour survived on the replica"
t_is "${SRC_AFTER}" \
    "$( printf '%s' "${REP_AFTER}" | tr ' ' '\n' | grep -v '^zrepl-' | tr '\n' ' ' )" \
    "the two ends were pruned identically"
t_like "${REP_AFTER}" 'zrepl-19990101T000000' \
    "a foreign snapshot older than every retention window was still left alone"

# --- the base is never pruned ----------------------------------------------
#
# Arranged rather than hoped for: strip the lineage down to ONE snapshot, old
# enough that the ladder would destroy it, present on both ends. It is the
# newest thing the two ends have in common, so it is the base of the next
# incremental send -- and destroying it because it aged out is how a lineage is
# lost quietly. Without the protected list this fails on both ends.
for s in $( src_snaps ); do
    [ "${s}" = "seance-alpha-${TS_ANCIENT}" ] && continue
    nz alpha destroy -r "${ARC_SRC}@${s}"
done
for s in $( rep_snaps ); do
    case "${s}" in
        zrepl-*) continue ;;
    esac
    nz bravo destroy -r "${ARC_ON_BRAVO}@${s}"
done

TS_BASE=$( date -u -r $(( NOW - 6 * 86400 )) +%Y%m%dT%H%M%SZ )
nz alpha snapshot -r "${ARC_SRC}@seance-alpha-${TS_BASE}"
nz bravo snapshot -r "${ARC_ON_BRAVO}@seance-alpha-${TS_BASE}"

t_is "$( src_snaps )" "seance-alpha-${TS_BASE} " \
    "the source lineage is now one six-day-old snapshot"

t_rc 0 "a prune-only tick over the aged lineage" \
    -- node_seance alpha repl --guest arc01 --peer bravo --locked

t_like "$( src_snaps )" "seance-alpha-${TS_BASE}" \
    "the incremental base survived the prune on the source, six days old and all"
t_like "$( rep_snaps )" "seance-alpha-${TS_BASE}" \
    "the incremental base survived the prune on the replica"

# ---------------------------------------------------------------------------
# Configuration drift -- the loud one
# ---------------------------------------------------------------------------

printf '\n# a well-meaning edit, on one node only\ndebounce=30\n' \
    >> "$( cluster_root charlie )/etc/seance.conf"

DRIFT_STATUS=$( node_seance alpha status 2>&1 )
DRIFT_STATUS_RC=$?
t_isnt "${DRIFT_STATUS_RC}" "0" \
    "status on alpha refuses to exit 0 once charlie's configuration has drifted"
t_like "${DRIFT_STATUS}" '^FAIL peer charlie: CONFIGURATION DIFFERS' \
    "and it says which node, in capitals"

DRIFT_VERIFY=$( node_seance alpha verify 2>&1 )
DRIFT_VERIFY_RC=$?
t_isnt "${DRIFT_VERIFY_RC}" "0" "verify on alpha refuses to exit 0 as well"
t_like "${DRIFT_VERIFY}" '^FAIL config: charlie HOLDS A DIFFERENT FILE' \
    "and names the node, the file, and that seance will not fix it for you"

# --- a replica that somebody wrote to (D-185) --------------------------------
#
# `written` on a replica must be 0: nothing here is the holder's to change
# between receives, and a replica with local writes cannot receive its next
# incremental at all -- zfs recv refuses with "destination has been modified"
# and seance will not -F past it. On the fleet that state went unnoticed until
# a tick failed hours later, so verify is made to say it first.
nz bravo set canmount=on "${WEB_ON_BRAVO}" > /dev/null 2>&1
nz bravo set mountpoint=/seance/scribble "${WEB_ON_BRAVO}" > /dev/null 2>&1
nz bravo mount "${WEB_ON_BRAVO}" > /dev/null 2>&1
cluster_exec bravo sh -c 'echo scribble > /seance/scribble/written-by-somebody' > /dev/null 2>&1
nz bravo unmount "${WEB_ON_BRAVO}" > /dev/null 2>&1
nz bravo inherit mountpoint "${WEB_ON_BRAVO}" > /dev/null 2>&1
nz bravo set canmount=noauto "${WEB_ON_BRAVO}" > /dev/null 2>&1

VERIFY_W=$( node_seance bravo verify 2>&1 )
t_like "${VERIFY_W}" "WARN replica: ${WEB_ON_BRAVO} has .* of LOCAL WRITES" \
    "verify names a replica that has been written to, before a tick has to fail on it"
t_like "${VERIFY_W}" 'next incremental for it will be REFUSED' \
    "and says the consequence, which is the thing an operator needs to know"

# Put it back, so the assertions after this are about what they say they are.
nz bravo rollback "$( nz bravo list -H -o name -t snapshot "${WEB_ON_BRAVO}" | tail -1 )" > /dev/null 2>&1
t_is "$( nz bravo get -H -o value written "${WEB_ON_BRAVO}" )" "0" \
    "and a rollback to the newest snapshot is what clears it"

# --- the identity comes BACK (D-183) ----------------------------------------
#
# LAST in this file on purpose: it runs an extra tick, and a tick that ran in
# the middle would change the snapshot and lag assertions above into a
# different test than the one they were written to be.
#
# A property somebody cleared -- or a replica received by a seance that
# predates this contract, which is the whole upgrade path -- is put back by the
# next tick, not left for a promotion to trip over at 03:00.
nz bravo inherit seance:guest "${WEB_ON_BRAVO}" > /dev/null 2>&1
t_is "$( nz bravo get -H -o value seance:guest "${WEB_ON_BRAVO}" )" "-" \
    "a cleared identity really is cleared, so the next assertion means something"
node_seance alpha repl --now > /dev/null 2>&1
t_is "$( nz bravo get -H -o value seance:guest "${WEB_ON_BRAVO}" )" "web01" \
    "and one more tick puts it back, which is how an upgraded fleet heals itself"

t_done
