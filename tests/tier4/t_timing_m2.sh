#!/bin/sh
# Tier 4 -- no M2 verb hangs, against a peer that accepts TCP and never answers.
#
# THE INJECTION, and why it is not a firewall. A peer that is switched off
# refuses the connection and every verb finds out in milliseconds; a peer
# behind a dropping firewall never completes the handshake and ssh's own
# ConnectTimeout ends it. The case neither of those covers -- and the case a
# half-dead machine actually produces -- is a peer whose TCP stack is up and
# whose sshd is not: the connection is ACCEPTED, a banner may even arrive, and
# then nothing ever comes back. ssh will wait for that for as long as it is
# allowed to, and what limits it is seance's own timeout(1) wrapper and
# nothing else. Measured here: an ssh to the listener below is killed at the
# budget, having produced no answer at all.
#
# So this file stands a black hole on the loopback -- a listener that accepts,
# writes an SSH banner and then sleeps -- points a configured peer at it, and
# runs every M2 verb that talks to a peer. Each one must return inside its
# budget, with a verdict line, and not by being killed.
#
# THE BUDGETS ARE LOWERED IN THIS SHELL, not in seance. TRANSPORT_CONNECT_TIMEOUT
# and TRANSPORT_CTL_TIMEOUT are library constants with no environment override,
# deliberately (D-75's reasoning): a site that needs to move them has a network
# problem it cannot configure its way out of. A test that assigns them in its
# own process takes exactly the path production takes -- and the alternative,
# waiting out the real ten and sixty seconds per probe, is a test nobody runs.
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
# The verdict-line grammar the tier-7 oracle holds every invocation to (D-55),
# used here rather than written out again: a verb that answered in time and
# said nothing an oracle recognises has not answered.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/sim/oracle.subr
. "${T_ROOT}/tests/cluster/sim/oracle.subr"

DIR=$( t_tmpdir )

SEANCE_TMP_REGISTRY="${DIR}/registry"
: > "${SEANCE_TMP_REGISTRY}"
export SEANCE_TMP_REGISTRY
t_at_exit 'seance_tmp_cleanup'

NOTIFY_TIMEOUT=1
TRANSPORT_CONNECT_TIMEOUT=1
TRANSPORT_CTL_TIMEOUT=2

# Every verb below must finish inside this. It is deliberately far larger than
# the sum of the budgets above: what is being asserted is that a verb TERMINATES
# on its own, not that it is quick, and a bound tight enough to fail on a busy
# workstation would be a flaky test rather than a strict one.
BOUND=30

# --- the black hole ---------------------------------------------------------
#
# `nc -k` keeps listening after each connection, so every probe below meets an
# open socket. The banner is produced by a loop on its stdin rather than per
# connection -- which is a fair model of the two shapes this failure really
# has: the first connection is answered with an SSH banner and then silence
# (ssh proceeds to the key exchange and waits, and only SEANCE's bound ends
# it), and the ones after it get an open socket and no banner at all (ssh's own
# ConnectTimeout ends those). Both are peers that accept TCP and never answer,
# and the file asserts a bound for each.
PORT=$(( 40000 + $$ % 9000 ))
cat > "${DIR}/blackhole.sh" <<EOF
while :; do printf 'SSH-2.0-blackhole_1.0\r\n'; sleep 3; done |
    nc -k -l 127.0.0.1 ${PORT} > /dev/null 2>&1
EOF
sh "${DIR}/blackhole.sh" < /dev/null > /dev/null 2>&1 &
BH_PID=$!
t_at_exit "kill ${BH_PID} 2>/dev/null; pkill -f 'nc -k -l 127.0.0.1 ${PORT}' 2>/dev/null"

# Wait for the bind, WITHOUT connecting: a connection made here would consume
# the banner the first assertion below is about.
LISTENING=0
i=0
while [ "${i}" -lt 25 ]; do
    if sockstat -4 -l 2>/dev/null | grep -q "127\.0\.0\.1:${PORT}"; then
        LISTENING=1
        break
    fi
    sleep 0.2
    i=$(( i + 1 ))
done

# --- syslog, redirected -----------------------------------------------------
SHIM="${DIR}/bin"
mkdir -p "${SHIM}"
cat > "${SHIM}/logger" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${LOGGER_LOG}"
exit 0
EOF
chmod 0755 "${SHIM}/logger"
LOGGER_LOG="${DIR}/logger.log"
export LOGGER_LOG
PATH="${SHIM}:${PATH}"
export PATH

# --- the fleet --------------------------------------------------------------
#
# alpha is the corpse, on TEST-NET-1 (RFC 5737), which exists so that a test
# may name an address nothing will answer on. charlie is the black hole.
CONF="${DIR}/seance.conf"
cat > "${CONF}" <<EOF
cadence=900
standby_root=pool0/%n/standby
ssh_port=${PORT}
ssh_extra_opts=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR

node_alpha_nodename=alpha
node_alpha_mgmt=192.0.2.11
node_alpha_heir=bravo
node_alpha_heir2=charlie

node_bravo_nodename=bravo
node_bravo_mgmt=192.0.2.12
node_bravo_heir=charlie

node_charlie_nodename=charlie
node_charlie_mgmt=127.0.0.1
node_charlie_heir=bravo
EOF
conf_load "${CONF}" || { echo "the fixture configuration did not load" >&2; exit 2; }

SEANCE_STATE_DIR="${DIR}/state"
SEANCE_RUN_DIR="${DIR}/run"
export SEANCE_STATE_DIR SEANCE_RUN_DIR
mkdir -p "${SEANCE_STATE_DIR}" "${SEANCE_RUN_DIR}"

SEANCE_MOCK_NODE=bravo
SEANCE_MOCK_WORKDIR="${DIR}/workdir"
SEANCE_MOCK_LOG="${DIR}/mock.log"
export SEANCE_MOCK_NODE SEANCE_MOCK_WORKDIR SEANCE_MOCK_LOG
mkdir -p "${SEANCE_MOCK_WORKDIR}"

PROMOTE_FORCE=""

# shellcheck disable=SC2329
zfs_children() { return 1; }

t_plan 25

# ---------------------------------------------------------------------------
# The black hole is a black hole
# ---------------------------------------------------------------------------

if [ "${LISTENING}" -eq 1 ]; then
    t_ok "the black-hole listener is accepting connections on 127.0.0.1:${PORT}"
else
    t_not_ok "the black-hole listener is accepting connections on 127.0.0.1:${PORT}"
fi

START=$( date -u +%s )
seance_ssh 127.0.0.1 'echo hello' > "${DIR}/bh.out" 2> "${DIR}/bh.err"
BH_RC=$?
BH_ELAPSED=$(( $( date -u +%s ) - START ))

t_is "${BH_RC}" "124" \
    "an ssh to it is KILLED by seance's own bound: this peer answers TCP and nothing else"
t_is "$( cat "${DIR}/bh.out" )" "" \
    "and produces no answer at all, which is what makes it worth testing against"
if [ "${BH_ELAPSED}" -ge "${TRANSPORT_CTL_TIMEOUT}" ] && [ "${BH_ELAPSED}" -le 10 ]; then
    t_ok "and it really did block: ${BH_ELAPSED}s, the whole budget and no more"
else
    t_not_ok "and it really did block: ${BH_ELAPSED}s, the whole budget and no more"
fi

# ---------------------------------------------------------------------------
# Every verb that talks to a peer
# ---------------------------------------------------------------------------

# bounded <label> <command...>
#
# Three assertions in one measurement, because they are three ways for the same
# run to have gone wrong: it must finish on its own inside BOUND, it must not
# be the harness's timeout that ended it, and the last thing it said must be a
# verdict line the tier-7 oracle would accept.
bounded()
{
    local _label _out _rc _start _elapsed _last

    _label=$1
    shift

    # stdout and stderr apart, deliberately: the verdict-line rule is about
    # STDOUT (stdout is data, stderr is diagnostics), and a check that read the
    # merged stream would pass on a diagnostic that happened to be shaped like
    # a verdict -- which is how this file first "passed" for three verbs.
    _out="${DIR}/out.$$"
    _start=$( date -u +%s )
    t_run_timeout "${BOUND}" "$@" > "${_out}" 2> "${_out}.err"
    _rc=$?
    _elapsed=$(( $( date -u +%s ) - _start ))

    if [ "${_rc}" -ne 124 ]; then
        t_ok "${_label} returns on its own (${_elapsed}s, exit ${_rc})"
    else
        t_not_ok "${_label} returns on its own (${_elapsed}s, exit ${_rc})"
        sed -e 's/^/# /' "${_out}" "${_out}.err"
    fi

    _last=$( awk 'NF > 0 { line = $0 } END { print line }' "${_out}" )
    if printf '%s\n' "${_last}" | grep -Eq "${ORACLE_VERDICT_RE}"; then
        t_ok "${_label} ends in a verdict line: [${_last}]"
    else
        t_not_ok "${_label} ends in a verdict line: [${_last}]"
        sed -e 's/^/# /' "${_out}"
    fi
}

bounded "placement --remote" placement_report 1
bounded "gate --check" gate_run check
bounded "gate" gate_run act
bounded "gate --release" gate_run release:web01
bounded "promote" promote_run alpha
bounded "failback" failback_run web01 0
bounded "failback-assist stop" failback_assist web01 stop
bounded "status" status_report 0

# ---------------------------------------------------------------------------
# And what they decided, which must be the fail-safe answer in every case
# ---------------------------------------------------------------------------

placement_report 1 > "${DIR}/placement.out" 2> "${DIR}/placement.err"
t_like "$( cat "${DIR}/placement.out" )" 'from 0 living peer\(s\)' \
    "the placement verdict counts the LIVING peers, so 'no claims' cannot be read out of 'nobody answered'"

gate_run act > "${DIR}/gate.out" 2>&1
t_like "$( cat "${DIR}/gate.out" )" 'NOT ONE PEER ANSWERED' \
    "the gate withholds the whole estate: a peer that cannot answer is not a peer with no claims"

promote_run alpha > "${DIR}/promote.out" 2>&1
t_like "$( cat "${DIR}/promote.out" )" '^rung 2 quorum: notify' \
    "the ladder freezes at quorum rather than promoting onto a fleet it cannot see"

# ---------------------------------------------------------------------------
# A site cannot lengthen the bound with ssh_extra_opts
#
# The key exists so that a site can ADD what ssh understands (D-35). It is
# appended after seance's own options, and ssh(1) says "for each parameter, the
# first obtained value will be used" -- so what a site adds cannot replace
# what seance set. That is the direction to be unable to move in, and it was
# worth measuring: the comment in lib/transport.subr used to claim the
# opposite.
# ---------------------------------------------------------------------------

cat > "${DIR}/override.conf" <<EOF
ssh_port=${PORT}
ssh_extra_opts=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o LogLevel=ERROR -o ConnectTimeout=90

node_alpha_nodename=alpha
node_alpha_mgmt=192.0.2.11
node_alpha_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=192.0.2.12
node_bravo_heir=alpha
EOF
conf_load "${DIR}/override.conf" || t_diag "the override configuration did not load"

t_like "$( transport_ssh_opts )" "ConnectTimeout=${TRANSPORT_CONNECT_TIMEOUT}.*ConnectTimeout=90" \
    "seance's own ConnectTimeout is on the command line BEFORE the site's"

START=$( date -u +%s )
seance_ssh_probe 127.0.0.1
OV_ELAPSED=$(( $( date -u +%s ) - START ))
if [ "${OV_ELAPSED}" -le 5 ]; then
    t_ok "and a site asking for ninety seconds still gets seance's bound (${OV_ELAPSED}s)"
else
    t_not_ok "and a site asking for ninety seconds still gets seance's bound (${OV_ELAPSED}s)"
fi

conf_load "${CONF}" || t_diag "reloading the fixture configuration failed"

t_done
