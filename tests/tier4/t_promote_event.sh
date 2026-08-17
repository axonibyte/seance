#!/bin/sh
# Tier 4 -- `promote-event`, the devd(8) target.
#
# devd(8) executes an action by forking `sh -c` and calling wait4 on it
# (sbin/devd/devd.cc, my_system, called from action::do_action), so its ENTIRE
# EVENT LOOP is blocked until this verb returns. Everything asserted here is
# about that sentence:
#
#   * it maps a vhid to a node, and refuses to guess when it cannot;
#   * it decides whether this node is armed, and notifies when it is not;
#   * when it is armed it DETACHES the promotion and RETURNS AT ONCE -- which
#     is the row this file exists for, and the row that was failing.
#
# THE DEFECT THIS FILE WOULD HAVE CAUGHT, found instead by a tier-6 stage and
# an ssh session: the detach was bounded with seance_run_timeout, and
# timeout(1) "runs as the reaper (see also procctl(2)) of the command and its
# descendants, and will wait for all the descendants to terminate" unless
# --foreground is given (timeout(1), IMPLEMENTATION NOTES). So the bound
# applied to the PROMOTION rather than to the launcher: devd blocked for the
# whole timeout, and then the promotion was killed part way through. The
# assertion below is on the wall clock, because that is the only thing that can
# tell the two apart -- both produce a process, and only one of them returns.
#
# The world here is one shim: `daemon`, which records its arguments and starts
# something that outlives it, exactly as the real one does. Everything else --
# the mapping, the arming, the notification -- is the real code.
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
# shellcheck source=../../lib/carp.subr
. "${T_ROOT}/lib/carp.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/gate.subr
. "${T_ROOT}/lib/gate.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/promote.subr
. "${T_ROOT}/lib/promote.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../mock-adapter.subr
. "${T_ROOT}/tests/mock-adapter.subr"

SEANCE_TMP_REGISTRY=$( t_tmpdir )/registry
: > "${SEANCE_TMP_REGISTRY}"
export SEANCE_TMP_REGISTRY
t_at_exit 'seance_tmp_cleanup'

NOTIFY_TIMEOUT=2

WORK=$( t_tmpdir )
SHIM="${WORK}/bin"
mkdir -p "${SHIM}"

# The shim that matters. It records its argv and then starts something that
# OUTLIVES IT, which is what daemon(8) does and what makes the wall-clock
# assertion below able to fail.
cat > "${SHIM}/daemon" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${WORLD_DIR}/daemon.log"
/bin/sh -c 'sleep 25' < /dev/null > /dev/null 2>&1 &
exit 0
EOF

cat > "${SHIM}/logger" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${WORLD_DIR}/logger.log"
exit 0
EOF

chmod 0755 "${SHIM}/daemon" "${SHIM}/logger"
PATH="${SHIM}:${PATH}"
export PATH

WORLD_DIR=${WORK}
export WORLD_DIR

SEANCE_MOCK_NODE=bravo
SEANCE_MOCK_WORKDIR="${WORK}/workdir"
SEANCE_MOCK_LOG="${WORK}/mock.log"
SEANCE_MOCK_SCRIPT="${WORK}/mock.script"
SEANCE_MOCK_VERB="${SHIM}/pretend-platform seance"
export SEANCE_MOCK_NODE SEANCE_MOCK_WORKDIR SEANCE_MOCK_LOG SEANCE_MOCK_SCRIPT
export SEANCE_MOCK_VERB
mkdir -p "${SEANCE_MOCK_WORKDIR}"
: > "${SEANCE_MOCK_SCRIPT}"

# conf <auto> <armed>  -- a three-node ring with CARP, armed as asked.
conf()
{
    local _f

    _f="${WORK}/seance.conf"
    {
        printf 'carp_interface=vtnet0\n'
        printf 'auto=%s\n' "$1"
        printf 'node_alpha_nodename=alpha\n'
        printf 'node_alpha_mgmt=alpha-mgmt.example.net\n'
        printf 'node_alpha_heir=bravo\n'
        printf 'node_alpha_heir2=charlie\n'
        printf 'node_alpha_vhid=1\n'
        printf 'node_alpha_vhid_ip=192.0.2.101/32\n'
        printf 'node_bravo_nodename=bravo\n'
        printf 'node_bravo_mgmt=bravo-mgmt.example.net\n'
        printf 'node_bravo_heir=charlie\n'
        printf 'node_bravo_heir2=alpha\n'
        printf 'node_bravo_vhid=2\n'
        printf 'node_bravo_vhid_ip=192.0.2.102/32\n'
        [ -n "$2" ] && printf 'node_bravo_auto_promote=%s\n' "$2"
        printf 'node_charlie_nodename=charlie\n'
        printf 'node_charlie_mgmt=charlie-mgmt.example.net\n'
        printf 'node_charlie_heir=alpha\n'
        printf 'node_charlie_heir2=bravo\n'
        printf 'node_charlie_vhid=3\n'
        printf 'node_charlie_vhid_ip=192.0.2.103/32\n'
    } > "${_f}"

    conf_load "${_f}"
}

# run <event>  -- promote_event, with a fresh log, timed on the wall clock.
RUN_OUT=""
RUN_RC=0
RUN_SECS=0
run()
{
    local _t0 _t1

    : > "${WORK}/daemon.log"
    : > "${WORK}/logger.log"

    _t0=$( date -u +%s )
    RUN_OUT=$( promote_event "$1" 2>&1 )
    RUN_RC=$?
    _t1=$( date -u +%s )
    RUN_SECS=$(( _t1 - _t0 ))
}

t_plan 24

# ---------------------------------------------------------------------------
# The argument contract
# ---------------------------------------------------------------------------

conf 1 alpha || t_diag "the configuration failed to load"

for bad in "" "1" "vtnet0" "@vtnet0" "x@vtnet0" "1@"; do
    t_rc 2 "promote-event refuses [${bad}]: it is not a CARP subsystem" \
        -- promote_event "${bad}"
done

# ---------------------------------------------------------------------------
# Mapping, and the two events that are not errors
# ---------------------------------------------------------------------------

run "9@vtnet0"
t_is "${RUN_RC}" "0" "a vhid no node in the configuration claims is not an error"
t_like "${RUN_OUT}" 'belongs to no node in this configuration' \
    "and says so: CARP is a broadcast protocol and the segment may be shared"
t_is "$( cat "${WORK}/daemon.log" )" "" "and nothing was detached for it"

run "2@vtnet0"
t_is "${RUN_RC}" "0" "this node's OWN vhid going MASTER is not an error either"
t_like "${RUN_OUT}" 'own identity, and becoming MASTER for it is what a boot looks like' \
    "and is named as what it is"
t_is "$( cat "${WORK}/daemon.log" )" "" "and nothing was detached for that either"

# ---------------------------------------------------------------------------
# Armed: detach, and RETURN
# ---------------------------------------------------------------------------

run "1@vtnet0"

t_is "${RUN_RC}" "0" "an armed node's event exits 0"
t_like "${RUN_OUT}" '^promote-event: CARP MASTER for alpha \(vhid 1 on vtnet0\)' \
    "it names the node the vhid stands for"
t_like "${RUN_OUT}" 'running detached' "and says it detached the promotion"
t_like "$( cat "${WORK}/daemon.log" )" \
    "^-f -S -T seance -l daemon -s notice ${SHIM}/pretend-platform seance promote alpha --auto\$" \
    "daemon(8) was given the platform's own verb, the dead node and --auto, and told to log to syslog"

# THE ROW THIS FILE EXISTS FOR. The shim leaves a child running for 25 s. A
# bound that reaps descendants -- which timeout(1) does unless --foreground --
# would make this take PROMOTE_EVENT_DETACH_TIMEOUT seconds and then kill the
# promotion. devd waits for this verb, so seconds here are seconds of a blocked
# event loop on a node in the middle of a failure.
t_rc 0 "promote-event RETURNS AT ONCE, rather than waiting for what it detached" \
    -- test "${RUN_SECS}" -lt "${PROMOTE_EVENT_DETACH_TIMEOUT}"

# ---------------------------------------------------------------------------
# Not armed: notify, and detach nothing
# ---------------------------------------------------------------------------

conf 0 alpha || t_diag "the auto=0 configuration failed to load"
run "1@vtnet0"
t_is "${RUN_RC}" "0" "with the fleet key auto at 0 the event still exits 0"
t_is "$( cat "${WORK}/daemon.log" )" "" "and detaches nothing"
t_like "$( cat "${WORK}/logger.log" )" \
    'CARP MASTER for alpha observed, automation not armed' \
    "and the notification says exactly why"

conf 1 "" || t_diag "the unarmed-node configuration failed to load"
run "1@vtnet0"
t_is "$( cat "${WORK}/daemon.log" )" "" \
    "a node whose own auto_promote is empty detaches nothing either"
t_like "${RUN_OUT}" 'automation is not armed here' \
    "and its own line says so"

# ---------------------------------------------------------------------------
# The wrapper itself
# ---------------------------------------------------------------------------

START=$( date -u +%s )
seance_run_timeout_detach 5 "${SHIM}/daemon" probe > /dev/null 2>&1
END=$( date -u +%s )
t_rc 0 "seance_run_timeout_detach returns when the command does, not when its child does" \
    -- test "$(( END - START ))" -lt 5

t_rc 2 "and it refuses a bound that is not a number" \
    -- seance_run_timeout_detach x /bin/true

t_done
