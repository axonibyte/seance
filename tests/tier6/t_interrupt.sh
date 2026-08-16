#!/bin/sh
# Tier 6, stage 'interrupt' -- a fat send killed mid-stream, and the tick that
# picks it up again.
#
# The design's promise is that an interrupted delta continues instead of
# restarting (design §4), and the mechanism is `zfs recv -s` plus the receive
# token the peer keeps. Nothing about that is worth believing without watching
# it happen, because the failure mode when it is wrong is invisible: a fat
# guest whose replication never completes inside its cadence, silently
# restarting from zero every tick, looking busy and making no progress.
#
# So: 512 MB of incompressible data, a real send over real ssh between two
# vnet jails, kill -9 to the sender, and then the three things that must be
# true afterwards --
#
#   1. the peer holds a receive_resume_token;
#   2. the half-received state is NOT visible as a snapshot -- a partial
#      replica that looked usable is the one outcome worse than no replica;
#   3. the next tick consumes the token, completes the lineage, and goes on to
#      send the increment it would have sent anyway.
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

stage_begin interrupt

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the interrupt stage builds jails and ZFS datasets; it needs root"
    echo "t_interrupt: must run as root" >&2
    exit 2
fi

t_plan 15

SN_ADAPTER="/usr/local/seance/tests/cluster/adapter-pseudo.subr"
SN_ENV="SEANCE_CONF=/etc/seance.conf SEANCE_STATE_DIR=/var/db/seance SEANCE_RUN_DIR=/var/run/seance SEANCE_ADAPTER=${SN_ADAPTER}"
SN_BIN="/usr/local/seance/bin/seance"

# shellcheck disable=SC2329
#   Invoked indirectly by t_rc, which runs the command after its '--'.
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

node_sh()
{
    local _n

    _n=$1
    shift

    # shellcheck disable=SC2086
    #   Deliberate word splitting, as above.
    cluster_exec "${_n}" env ${SN_ENV} sh -c "$*" < /dev/null
}

nz()
{
    local _n

    _n=$1
    shift

    cluster_exec "${_n}" zfs "$@" < /dev/null
}

# ---------------------------------------------------------------------------
# Two nodes are enough for this question
# ---------------------------------------------------------------------------

cluster_up 2 || { t_diag "cluster_up failed"; t_done; }

BASE_DS=$( cluster_base_dataset )
ALPHA_DS=$( cluster_dataset alpha )

CONF=$( t_tmpdir )/seance.conf
cat > "${CONF}" <<EOF
cadence=60
retention_recent=14400
retention_hourly=172800
ssh_user=root
ssh_port=22
ssh_extra_opts=-i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
standby_root=${BASE_DS}/%n/standby

node_alpha_nodename=alpha
node_alpha_mgmt=$( cluster_ip alpha )
node_alpha_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=$( cluster_ip bravo )
node_bravo_heir=alpha
EOF

for n in alpha bravo; do
    cp "${CONF}" "$( cluster_root "${n}" )/etc/seance.conf"
done

t_rc 0 "the two-node configuration validates" -- node_seance alpha config --check

node_sh alpha ". ${SN_ADAPTER}; adapter_init && pseudo_guest_create fat01 jail alpha" ||
    t_diag "creating fat01 failed"

# Incompressible, so that the stream is as large as the data and the send takes
# long enough to be caught in the act.
cluster_exec alpha dd if=/dev/random of=/seance/fat01/blob bs=1m count=512 \
    status=none < /dev/null || t_diag "writing fat01's blob failed"

REPLICA="$( cluster_dataset bravo )/standby/alpha/fat01"

# ---------------------------------------------------------------------------
# Kill the send mid-stream
# ---------------------------------------------------------------------------

node_seance alpha repl --now > "$( t_tmpdir )/tick1.log" 2>&1 &
TICK=$!

killed=no
i=0
while [ "${i}" -lt 300 ]; do
    if cluster_exec alpha pgrep -f 'zfs send' > /dev/null 2>&1 < /dev/null; then
        cluster_exec alpha pkill -9 -f 'zfs send' < /dev/null
        killed=yes
        break
    fi
    kill -0 "${TICK}" 2>/dev/null || break
    i=$(( i + 1 ))
    sleep 0.2
done

wait "${TICK}" 2>/dev/null
TICK_RC=$?

t_is "${killed}" "yes" "the zfs send was caught running and killed mid-stream"
t_isnt "${TICK_RC}" "0" "the tick reported the pair as failed rather than as done"

# ---------------------------------------------------------------------------
# What the peer is left holding
# ---------------------------------------------------------------------------

TOKEN=$( nz bravo get -H -o value receive_resume_token "${REPLICA}" 2>/dev/null )

t_rc 0 "the partially received replica dataset exists on bravo" \
    -- nz bravo list -H -o name "${REPLICA}"
t_isnt "${TOKEN}" "-" "bravo holds a receive_resume_token for it"
t_isnt "${TOKEN}" "" "and the token is not empty"

# The dataset whose receive was interrupted, and only it: a partial replica
# that looked like a usable snapshot is the one outcome worse than no replica.
#
# Its siblings are a separate question and a deliberate one. seance sends a
# guest's datasets one at a time, so a tick that dies part way through leaves
# some of them at the new snapshot and some at the old -- observed here: fat01
# itself has nothing, while fat01/sys, which is small and went first-to-finish,
# has the tick's snapshot. That is per-dataset lineage working, not a defect,
# and it is why promotion (M2) must choose the newest snapshot common to ALL of
# a guest's replica datasets rather than trusting the root's. Recorded in
# docs/repl-wire.md so that M2 meets it as a requirement rather than as a
# surprise.
t_is "$( nz bravo list -H -o name -t snapshot "${REPLICA}" | tr '\n' ' ' )" "" \
    "the interrupted dataset shows no snapshot at all: there is nothing there to promote"

SRC_SNAPS=$( nz alpha list -H -o name -t snapshot "${ALPHA_DS}/fat01" |
    sed 's/.*@//' | sort | tr '\n' ' ' )
t_like "${SRC_SNAPS}" '^seance-alpha-[0-9]{8}T[0-9]{6}Z $' \
    "the source kept the snapshot it was sending; only the transfer died"

# ---------------------------------------------------------------------------
# The next tick resumes rather than restarting
# ---------------------------------------------------------------------------

# More data first, so that the tick has both jobs to do: finish the interrupted
# receive AND send the increment that has accumulated since. A resume that only
# works when nothing else changed is not the resume the design promised.
cluster_exec alpha sh -c 'echo after-the-interrupt > /seance/fat01/marker' < /dev/null

TICK2=$( node_seance alpha repl --now 2>&1 )
TICK2_RC=$?

t_is "${TICK2_RC}" "0" "the next tick succeeded"
t_like "${TICK2}" 'resuming an interrupted receive' \
    "and said out loud that it was resuming rather than restarting"

t_is "$( nz bravo get -H -o value receive_resume_token "${REPLICA}" )" "-" \
    "the resume token is consumed"

REP_SNAPS=$( nz bravo list -H -o name -t snapshot "${REPLICA}" |
    sed 's/.*@//' | sort | tr '\n' ' ' )
SRC_SNAPS=$( nz alpha list -H -o name -t snapshot "${ALPHA_DS}/fat01" |
    sed 's/.*@//' | sort | tr '\n' ' ' )

t_is "${REP_SNAPS}" "${SRC_SNAPS}" \
    "the replica's lineage is now exactly the source's: the interrupted snapshot and the one after it"

t_stdout_is "after-the-interrupt" \
    "the increment that accumulated during the outage arrived too" \
    -- node_sh bravo "mkdir -p /tmp/probe &&
        zfs set mountpoint=/tmp/probe ${REPLICA} &&
        zfs mount ${REPLICA} &&
        cat /tmp/probe/marker &&
        zfs umount ${REPLICA} &&
        zfs inherit mountpoint ${REPLICA}"

# The law holds through a resumed receive as well: a stream finished by
# 'zfs send -t' must not arrive with a mountpoint of its own either.
t_is "$( nz bravo get -H -o value,source mountpoint "${REPLICA}" | tr '\t' ' ' |
    sed 's/ .*//' )" "none" \
    "the resumed replica carries no mountpoint of its own"

# ---------------------------------------------------------------------------
# And normal service resumes
# ---------------------------------------------------------------------------

cluster_exec alpha sh -c 'echo and-another >> /seance/fat01/marker' < /dev/null

t_rc 0 "a plain incremental tick works again afterwards" \
    -- node_seance alpha repl --now

t_done
