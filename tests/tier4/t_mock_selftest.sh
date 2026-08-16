#!/bin/sh
# Tier 4 -- the mock adapter's own self-test (TESTING.md §7's rule, applied one
# tier early).
#
# "An invariant that never fires is indistinguishable from a passing suite."
# The same is true of an injector: a mock whose 'fail' outcome quietly returned
# success would turn every fault-injection row in this tier green, and the
# suite would report that seance survives faults it was never shown. So each
# outcome is checked here, once, against what it claims to do -- before any
# ladder is driven with it.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../mock-adapter.subr
. "${T_ROOT}/tests/mock-adapter.subr"

DIR=$( t_tmpdir )
SCRIPT="${DIR}/script"
SEANCE_MOCK_SCRIPT=${SCRIPT}
SEANCE_MOCK_LOG="${DIR}/log"
export SEANCE_MOCK_SCRIPT SEANCE_MOCK_LOG

OUT=""
ERR=""
RC=0

# call <function> [args...]  -- run it, keeping stdout, stderr and the status.
call()
{
    "$@" > "${DIR}/out" 2> "${DIR}/err"
    RC=$?
    OUT=$( cat "${DIR}/out" )
    ERR=$( cat "${DIR}/err" )
}

t_plan 21

# --- ok ----------------------------------------------------------------------
printf 'adapter_node_self\tok\tcharlie\n' > "${SCRIPT}"
call adapter_node_self
t_is "${OUT}" "charlie" "ok: the payload is stdout"
t_is "${RC}" "0" "ok: exit 0"

printf 'adapter_node_self\tok\t-\n' > "${SCRIPT}"
call adapter_node_self
t_is "${OUT}" "" "ok with '-': no output at all"
t_is "${RC}" "0" "ok with '-': exit 0"

# --- fail --------------------------------------------------------------------
printf 'adapter_guest_start\tfail\tjstart: no such jail\n' > "${SCRIPT}"
call adapter_guest_start web01
t_is "${RC}" "1" "fail: exit 1"
t_is "${OUT}" "" "fail: nothing on stdout"
t_is "${ERR}" "jstart: no such jail" "fail: the payload is stderr"

# --- garbage -----------------------------------------------------------------
printf 'adapter_guest_list\tgarbage\t<!DOCTYPE html>\n' > "${SCRIPT}"
call adapter_guest_list
t_is "${RC}" "0" "garbage: exit 0, because that is the point of it"
t_is "${OUT}" "<!DOCTYPE html>" "garbage: the payload is stdout"

# --- empty0: the crashed verifier -------------------------------------------
printf 'adapter_guest_running\tempty0\n' > "${SCRIPT}"
call adapter_guest_running web01
t_is "${RC}" "0" "empty0: exit 0"
t_is "${OUT}" "" "empty0: and nothing printed -- success with no answer"

# --- usage -------------------------------------------------------------------
printf 'adapter_carp_state\tusage\tno such option\n' > "${SCRIPT}"
call adapter_carp_state 1
t_is "${RC}" "2" "usage: exit 2"
t_is "${ERR}" "no such option" "usage: the payload is stderr"

# --- multi-line payloads -----------------------------------------------------
printf 'adapter_guest_list\tok\ta\\tjail\\t1\\t1\\t1\\nb\\tbhyve\\t0\\t0\\t0\n' \
    > "${SCRIPT}"
call adapter_guest_list
t_is "$( printf '%s\n' "${OUT}" | wc -l | tr -d ' ' )" "2" \
    "a payload's \\n is a line break, so a listing can be scripted"
t_like "${OUT}" '^a	jail	1	1	1$' \
    "a payload's \\t is a field separator"

# --- the more specific key wins ----------------------------------------------
printf 'adapter_guest_type\tok\tbhyve\nadapter_guest_type web01\tfail\tgone\n' \
    > "${SCRIPT}"
call adapter_guest_type web01
t_is "${RC}" "1" "a key with an argument beats the same key without one"
call adapter_guest_type db01
t_is "${OUT}" "bhyve" "and the general key still answers for other arguments"

# --- unscripted calls fall through to the fixtures ---------------------------
: > "${SCRIPT}"
call adapter_guest_type web01
t_is "${OUT}" "jail" "an unscripted call answers from the fictional world"

# --- a malformed script is a contract error, not a pass ----------------------
printf 'adapter_node_self\tsucceed-quietly\n' > "${SCRIPT}"
call adapter_node_self
t_is "${RC}" "2" "an outcome word the mock does not know is exit 2"

# --- timeout ------------------------------------------------------------------
SEANCE_MOCK_TIMEOUT=1
export SEANCE_MOCK_TIMEOUT
printf 'adapter_node_self\ttimeout\n' > "${SCRIPT}"
t_run_timeout 1 adapter_node_self > "${DIR}/out" 2>&1
t_is "$?" "124" "timeout: the call does not answer, and the wrapper says so"

# --- the log ------------------------------------------------------------------
t_like "$( cat "${SEANCE_MOCK_LOG}" )" '^adapter_guest_start web01$' \
    "the log records the function and its arguments"

t_done
