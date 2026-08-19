#!/bin/sh
# Tier 4 -- how long `promote-event` may take, which is: no time at all.
#
# devd(8) executes an action by forking `sh -c` and calling wait4 on it
# (sbin/devd/devd.cc, my_system, called from action::do_action), so its whole
# event loop is blocked until this verb returns. The events queued behind it
# are the ones about the SECOND death. That is why D-127 exists -- a bound that
# reaped the promotion instead of the launcher blocked devd for ten seconds and
# then killed the promotion -- and it is why every path out of this verb is
# bounded rather than merely usually quick.
#
# This file measures each of those paths against ONE SECOND on the wall clock,
# with the thing that could hang made to hang for real:
#
#   * the promotion itself (the ladder takes minutes: that is the point of
#     detaching it);
#   * the ladder's transport -- an ssh to a node that accepts TCP and never
#     answers, which is what the corpse's neighbours look like;
#   * the platform's own verb, if invoking it were to block;
#   * daemon(8) refusing to return, which is the one path that has to wait, and
#     waits exactly PROMOTE_EVENT_DETACH_TIMEOUT;
#   * the notification, when a site's notify_cmd hangs.
#
# The last one is the reason this file is not a subset of
# t_promote_event.sh: a notification is the seance half of somebody else's
# script, and a devd action that waits for it is a devd action that waits for
# a mail server.
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

WORK=$( t_tmpdir )
SHIM="${WORK}/bin"
mkdir -p "${SHIM}"

SEANCE_TMP_REGISTRY="${WORK}/registry"
: > "${SEANCE_TMP_REGISTRY}"
export SEANCE_TMP_REGISTRY
t_at_exit 'seance_tmp_cleanup'

SEANCE_RUN_DIR="${WORK}/run"
export SEANCE_RUN_DIR

# daemon(8): consumes its options, starts the command, returns. WORLD_DAEMON_HANG
# makes it the one thing that does not return, which is what the detach bound
# exists for.
cat > "${SHIM}/daemon" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${WORLD_DIR}/daemon.log"
if [ "${WORLD_DAEMON_HANG:-0}" = "1" ]; then
    sleep 300
    exit 0
fi
while [ $# -gt 0 ]; do
    case "$1" in
        -f) shift ;;
        -S) shift ;;
        -T|-l|-s|-p|-P|-u|-o) shift 2 ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || exit 1
"$@" < /dev/null >> "${WORLD_DIR}/detached.log" 2>&1 &
exit 0
EOF

# The platform's own verb, standing in for the ladder. It takes as long as a
# promotion does; WORLD_VERB_HANG makes it take longer than this test will run.
cat > "${SHIM}/pretend-platform" <<'EOF'
#!/bin/sh
set -u
printf 'ladder: %s\n' "$*" >> "${WORLD_DIR}/ladders.log"
if [ "${WORLD_VERB_HANG:-0}" = "1" ]; then
    sleep 300
else
    sleep 25
fi
exit 0
EOF

# The transport a detached ladder would use. Answering nothing at all is what
# an ssh to a host that has just died looks like before the connect times out.
cat > "${SHIM}/ssh" <<'EOF'
#!/bin/sh
sleep 300
exit 255
EOF

cat > "${SHIM}/logger" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${WORLD_DIR}/logger.log"
exit 0
EOF

# A site's notify_cmd, hanging: the seance half of somebody else's script.
cat > "${SHIM}/hangingnotify" <<'EOF'
#!/bin/sh
cat > /dev/null
sleep 300
exit 0
EOF

cat > "${SHIM}/fastnotify" <<'EOF'
#!/bin/sh
set -u
cat >> "${WORLD_DIR}/notify.body"
printf '%s\n' "$1" >> "${WORLD_DIR}/notify.subject"
exit 0
EOF

chmod 0755 "${SHIM}/daemon" "${SHIM}/pretend-platform" "${SHIM}/ssh" \
    "${SHIM}/logger" "${SHIM}/hangingnotify" "${SHIM}/fastnotify"
PATH="${SHIM}:${PATH}"
export PATH

WORLD_DIR=${WORK}
export WORLD_DIR
WORLD_DAEMON_HANG=0
WORLD_VERB_HANG=0
export WORLD_DAEMON_HANG WORLD_VERB_HANG

SEANCE_MOCK_NODE=bravo
SEANCE_MOCK_WORKDIR="${WORK}/workdir"
SEANCE_MOCK_LOG="${WORK}/mock.log"
SEANCE_MOCK_SCRIPT="${WORK}/mock.script"
SEANCE_MOCK_VERB="${SHIM}/pretend-platform seance"
export SEANCE_MOCK_NODE SEANCE_MOCK_WORKDIR SEANCE_MOCK_LOG SEANCE_MOCK_SCRIPT
export SEANCE_MOCK_VERB
mkdir -p "${SEANCE_MOCK_WORKDIR}"
: > "${SEANCE_MOCK_SCRIPT}"

# conf <auto> <armed> <notify_cmd-or-empty>
conf()
{
    local _f

    _f="${WORK}/seance.conf"
    {
        printf 'carp_interface=vtnet0\n'
        printf 'auto=%s\n' "$1"
        [ -n "$3" ] && printf 'notify_cmd=%s\n' "$3"
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

RUN_OUT=""
RUN_RC=0
RUN_SECS=0
run()
{
    local _t0 _t1

    : > "${WORK}/daemon.log"
    : > "${WORK}/logger.log"
    : > "${WORK}/ladders.log"
    rm -rf "${SEANCE_RUN_DIR}"

    _t0=$( date -u +%s )
    RUN_OUT=$( promote_event "$1" 2>&1 )
    RUN_RC=$?
    _t1=$( date -u +%s )
    RUN_SECS=$(( _t1 - _t0 ))
}

# within_a_second <name>  -- one second of wall clock, measured at one-second
# resolution, so the bound asserted is "the second it started in, or the next".
within_a_second()
{
    t_rc 0 "$1 (${RUN_SECS}s)" -- test "${RUN_SECS}" -le 1
}

t_plan 17

# ---------------------------------------------------------------------------
# The armed path: the ladder is detached, so nothing it does is devd's problem
# ---------------------------------------------------------------------------

conf 1 alpha "${SHIM}/fastnotify" || t_diag "the armed configuration failed to load"

run "1@vtnet0"
within_a_second "an armed event returns inside a second, with a ladder that runs for 25s"
t_like "${RUN_OUT}" 'running detached' "and it says it detached the promotion"

WORLD_VERB_HANG=1
run "1@vtnet0"
within_a_second "and inside a second when the platform's verb itself never returns"
WORLD_VERB_HANG=0

# The ssh shim answers nothing for five minutes. The ladder's transport is
# behind the detach, so a corpse's neighbours cannot hold devd's event loop.
run "1@vtnet0"
within_a_second "and inside a second with every ssh the ladder would make hanging"

# The one path that waits, and waits exactly as long as it says it does.
WORLD_DAEMON_HANG=1
T0=$( date -u +%s )
OUT=$( promote_event "1@vtnet0" 2>&1 )
T1=$( date -u +%s )
WORLD_DAEMON_HANG=0
ELAPSED=$(( T1 - T0 ))

t_rc 0 "a daemon(8) that never returns is bounded by PROMOTE_EVENT_DETACH_TIMEOUT (${ELAPSED}s)" \
    -- test "${ELAPSED}" -le $(( PROMOTE_EVENT_DETACH_TIMEOUT + 6 ))
t_rc 0 "and it is not returned from EARLY either: the bound is the wait" \
    -- test "${ELAPSED}" -ge "${PROMOTE_EVENT_DETACH_TIMEOUT}"
t_like "${OUT}" 'NOTHING WAS PROMOTED' \
    "and it says nothing was promoted, rather than reporting a promotion it could not start"

# ---------------------------------------------------------------------------
# The paths that decide not to act
# ---------------------------------------------------------------------------

run "255@vtnet0"
within_a_second "a vhid this fleet does not claim is answered inside a second"

run "2@vtnet0"
within_a_second "and so is this node's own vhid"

run "notasubsystem"
within_a_second "and so is an argument that is not a CARP subsystem at all"
t_is "${RUN_RC}" "2" "-- with rc 2, because that one is a contract error"

# ---------------------------------------------------------------------------
# The notification: somebody else's script, on devd's clock
# ---------------------------------------------------------------------------

conf 1 "" "${SHIM}/fastnotify" || t_diag "the unarmed configuration failed to load"
run "1@vtnet0"
within_a_second "an unarmed node notifies and returns inside a second"
t_like "${RUN_OUT}" 'automation is not armed here' "and says what it did instead"

conf 1 "" "${SHIM}/hangingnotify" || t_diag "the hanging-notify configuration failed to load"
run "1@vtnet0"
within_a_second "AND IT RETURNS INSIDE A SECOND WHEN THE SITE'S notify_cmd HANGS"
t_like "${RUN_OUT}" 'automation is not armed here' \
    "-- with the same answer, because a notification is not a verdict"

# The armed path notifies too when it cannot start the promotion, and a devd
# that is blocked THERE is blocked in the middle of a death.
conf 1 alpha "${SHIM}/hangingnotify" || t_diag "the armed hanging-notify configuration failed to load"
# The adapter answers "verb" with empty output and rc 0 -- the
# empty-output-with-success class, which this verb treats as not knowing how to
# invoke itself. Scripted rather than unset: an unset SEANCE_MOCK_VERB is a
# mock with a default, which is a different world from a platform that cannot
# answer.
printf 'adapter_fact verb\tempty0\n' > "${SEANCE_MOCK_SCRIPT}"
run "1@vtnet0"
: > "${SEANCE_MOCK_SCRIPT}"
within_a_second "an armed node that cannot invoke itself pages and returns inside a second"
t_like "${RUN_OUT}" 'NOTHING WAS PROMOTED' "and says so"

t_done
