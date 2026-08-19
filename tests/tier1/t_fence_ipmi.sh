#!/bin/sh
# Tier 1 -- the shipped fence driver, drivers/fence_ipmi (TESTING.md §2,
# HANDOFF.md §2.4, decision D-44 items 1-2).
#
# No BMC is involved and none is needed: tests/drivers/ipmitool is a scripted
# stand-in put first on PATH, and FENCE_SHIM_MODE decides what the imaginary
# BMC does. What is under test is the driver's *judgement* -- which BMC
# behaviour becomes exit 0, which becomes exit 1, and which becomes exit 2 --
# because that mapping is what the promotion ladder acts on:
#
#   0  verified off        -> promotion proceeds
#   1  refused / still on  -> hard abort, un-forceable (D-44 item 1)
#   2  cannot determine    -> stop at notify; a human may --force
#
# A test that let "command accepted" pass as 0, or that let an ambiguous
# failure look like 2 when the BMC had actually refused, would be handing back
# the split brain the whole product exists to prevent. That is why the table
# below has a row for every mode in both directions and why the exit code is
# asserted separately from the verdict line.
#
# The other invariant: the password never leaves the passfile. Every run greps
# the driver's stdout, its stderr and the shim's argv log for the secret. The
# shim deliberately echoes its argv into all three, so if the driver ever
# passed `-P <password>` instead of `-f <passfile>`, these assertions fail.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (HANDOFF.md §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

DRIVER="${T_ROOT}/drivers/fence_ipmi"

# The shim first on PATH. Nothing else in that directory, so this redirects
# ipmitool and only ipmitool.
PATH="${T_ROOT}/tests/drivers:${PATH}"
export PATH

# Deliberately distinctive, and 20 characters, which is ipmitool's maximum for
# IPMI v2.0 (ipmitool(1), "Passwords").
SECRET='zzSeanceSecret012345'

# The driver must never inherit a credentials path from the environment except
# where a test sets one on purpose.
unset SEANCE_FENCE_IPMI_CONF
unset SEANCE_FENCE_TIMEOUT

RUN_DIR=""
RUN_RC=0
RUN_OUT=""
RUN_ERR=""
RUN_LOG=""
RUN_OUTLINES=0
RUN_ELAPSED=0

# mkfix  -- print a fresh fixture directory holding a good conf and passfile.
mkfix()
{
    local _d

    _d=$( t_tmpdir )

    printf '%s\n' "${SECRET}" > "${_d}/pass"
    chmod 600 "${_d}/pass"

    {
        printf '# credentials for the fictional site\n'
        printf 'target_alpha_host=alpha-bmc.example.net\n'
        printf 'target_alpha_user=fenceuser\n'
        printf 'target_alpha_passfile=%s/pass\n' "${_d}"
        printf 'target_alpha_extra=-C 17\n'
    } > "${_d}/conf"
    chmod 600 "${_d}/conf"

    printf '%s\n' "${_d}"
}

# mkfix_extra <extra>  -- a fixture whose target_alpha_extra is <extra>.
mkfix_extra()
{
    local _d

    _d=$( mkfix )
    sed -e "s|^target_alpha_extra=.*|target_alpha_extra=$1|" "${_d}/conf" \
        > "${_d}/conf.tmp"
    mv "${_d}/conf.tmp" "${_d}/conf"
    chmod 600 "${_d}/conf"

    printf '%s\n' "${_d}"
}

# run_fence <mode> <driver args...>
#
# Runs the driver with the shim scripted to <mode>, capturing stdout, stderr,
# the shim's argv log and the wall-clock time. Every run gets its own log and
# counter file, so the off-after-N counter never leaks between rows.
run_fence()
{
    local _mode _d _t0

    _mode=$1
    shift

    _d=$( t_tmpdir )
    : > "${_d}/log"

    _t0=$( date +%s )
    FENCE_SHIM_MODE="${_mode}" \
    FENCE_SHIM_LOG="${_d}/log" \
    FENCE_SHIM_STATE="${_d}/state" \
        "${DRIVER}" "$@" > "${_d}/out" 2> "${_d}/err"
    RUN_RC=$?
    RUN_ELAPSED=$(( $( date +%s ) - _t0 ))

    RUN_DIR=${_d}
    RUN_LOG="${_d}/log"
    RUN_OUT=$( cat "${_d}/out" )
    RUN_ERR=$( cat "${_d}/err" )
    RUN_OUTLINES=$( awk 'END { print NR + 0 }' "${_d}/out" )

    return 0
}

# t_no_secret <name>  -- the password appears in none of the three streams.
t_no_secret()
{
    if grep -q -F -e "${SECRET}" \
        "${RUN_DIR}/out" "${RUN_DIR}/err" "${RUN_DIR}/log"; then
        t_not_ok "$1"
        t_diag "the password appears in the driver's output or in the argv log"
        grep -l -F -e "${SECRET}" \
            "${RUN_DIR}/out" "${RUN_DIR}/err" "${RUN_DIR}/log" |
            sed -e 's/^/# leaked in: /'
    else
        t_ok "$1"
    fi
}

t_plan 177

FIX=$( mkfix )

# --- the table: every shim mode against both actions ------------------------
#
# mode | action | timeout | expected rc | expected verdict word
#
# Where the timeout is small it is load-bearing: stays-on and hang can only
# end by exhausting the budget, and a suite that waited the default 60 s for
# them would be a suite nobody runs.

while IFS='|' read -r mode action tmo rc state; do
    case "${mode}" in
        ''|'#'*) continue ;;
    esac

    run_fence "${mode}" "${action}" alpha --config "${FIX}/conf" \
        --timeout "${tmo}"

    t_is "${RUN_RC}" "${rc}" "${mode}/${action}: exit ${rc}"
    t_like "${RUN_OUT}" "^fence_ipmi: alpha ${state}( |\$)" \
        "${mode}/${action}: verdict says ${state}"
    t_is "${RUN_OUTLINES}" "1" "${mode}/${action}: exactly one verdict line"
    t_no_secret "${mode}/${action}: no password in any stream"
done <<'TABLE'
off-immediately|off|60|0|off
off-immediately|status|60|0|off
off-after-1|off|30|0|off
off-after-1|status|30|1|on
stays-on|off|2|1|on
stays-on|status|2|1|on
refused|off|60|1|refused
refused|status|60|2|unknown
unreachable|off|60|2|unknown
unreachable|status|60|2|unknown
garbage|off|60|2|unknown
garbage|status|60|2|unknown
empty0|off|60|2|unknown
empty0|status|60|2|unknown
hang|off|2|2|unknown
hang|status|2|2|unknown
TABLE

# --- what the verdict lines actually say ------------------------------------

run_fence stays-on off alpha --config "${FIX}/conf" --timeout 2
t_like "${RUN_OUT}" '^fence_ipmi: alpha on still powered on after [0-9]+s' \
    "off: still-on names the elapsed time and is not a success"

run_fence refused off alpha --config "${FIX}/conf"
t_like "${RUN_OUT}" '^fence_ipmi: alpha refused ' \
    "off: a refusal is reported as refused, not as unknown"

run_fence empty0 off alpha --config "${FIX}/conf"
t_like "${RUN_OUT}" 'contract violation' \
    "off: exit 0 with no output is named as a contract violation"

# --- the argv: -f, never -P -------------------------------------------------

run_fence off-immediately off alpha --config "${FIX}/conf"
log=$( cat "${RUN_LOG}" )
t_like "${log}" "-f ${FIX}/pass" "argv: the password goes as -f <passfile>"
t_unlike "${log}" "-P " "argv: never -P"
t_like "${log}" '^-I lanplus ' "argv: the interface is lanplus"
t_like "${log}" "-H alpha-bmc.example.net" "argv: the BMC address is passed"
t_like "${log}" "-U fenceuser" "argv: the user is passed"
t_like "${log}" "-C 17" "argv: the extra arguments are passed through"
t_like "${log}" 'chassis power off' "argv: the off command is chassis power off"
t_like "${log}" 'chassis power status' "argv: the verification reads the status"

# The counter proves the poll loop really polls rather than reading once, and
# this is also where the successful verdict's shape is pinned: three reads that
# say on, a fourth that says off, one verdict line and a silent stderr.
run_fence off-after-3 off alpha --config "${FIX}/conf" --timeout 30
polls=$( grep -c 'chassis power status' "${RUN_LOG}" )
t_is "${polls}" "4" "off: polls until the power actually reads off"
t_is "${RUN_RC}" "0" "off: and then reports verified off"
t_like "${RUN_OUT}" '^fence_ipmi: alpha off verified after [0-9]+s$' \
    "off: the verdict reports how long verification took"
t_is "${RUN_ERR}" "" "off: a fence that worked says nothing on stderr"

# --- redaction --------------------------------------------------------------

run_fence refused off alpha --config "${FIX}/conf"
t_like "${RUN_ERR}" '-f <redacted>' \
    "redaction: the echoed command line shows -f <redacted>"
t_unlike "${RUN_ERR}" "-f ${FIX}/pass" \
    "redaction: the passfile path is not echoed back from ipmitool's output"
t_like "${RUN_ERR}" 'Insufficient privilege level' \
    "redaction: the BMC's own message still reaches the operator"

# --- --help -----------------------------------------------------------------

run_fence off-immediately --help
t_is "${RUN_RC}" "0" "--help: exit 0"
t_like "${RUN_OUT}" '^usage: fence_ipmi off' "--help: usage on stdout"
t_like "${RUN_OUT}" 'status  read power state' "--help: documents status"
t_like "${RUN_OUT}" 'target_<name>_passfile' \
    "--help: documents the credentials file"
t_unlike "${RUN_OUT}" '^fence_ipmi: ' \
    "--help: prints no verdict line, having fenced nothing"
t_is "${RUN_ERR}" "" "--help: says nothing on stderr"

# --- usage errors -----------------------------------------------------------

run_fence off-immediately
t_is "${RUN_RC}" "2" "no action: exit 2"
t_like "${RUN_OUT}" '^fence_ipmi: - unknown ' "no action: verdict on stdout"

run_fence off-immediately poweroff alpha --config "${FIX}/conf"
t_is "${RUN_RC}" "2" "unknown action: exit 2"
t_like "${RUN_OUT}" '^fence_ipmi: - unknown ' "unknown action: verdict"

run_fence off-immediately off
t_is "${RUN_RC}" "2" "no target: exit 2"

run_fence off-immediately off alpha --config "${FIX}/conf" --wat
t_is "${RUN_RC}" "2" "unknown option: exit 2"

run_fence off-immediately off alpha --config
t_is "${RUN_RC}" "2" "--config without a value: exit 2"

run_fence off-immediately off alpha --config "${FIX}/conf" --timeout
t_is "${RUN_RC}" "2" "--timeout without a value: exit 2"

for bad in 0 3601 abc -1 ''; do
    run_fence off-immediately off alpha --config "${FIX}/conf" \
        --timeout "${bad}"
    t_is "${RUN_RC}" "2" "--timeout '${bad}': exit 2"
done

run_fence off-immediately off 'alpha-bmc.example.net' --config "${FIX}/conf"
t_is "${RUN_RC}" "2" "a BMC address as the target: exit 2"
t_like "${RUN_ERR}" 'not an address' \
    "a BMC address as the target: says the target names an entry"

run_fence off-immediately off bravo --config "${FIX}/conf"
t_is "${RUN_RC}" "2" "unknown target: exit 2"
t_like "${RUN_OUT}" '^fence_ipmi: bravo unknown ' "unknown target: verdict"
t_like "${RUN_ERR}" 'no entry for target' "unknown target: names the target"
t_is "$( cat "${RUN_LOG}" )" "" "unknown target: ipmitool is never called"

# --- the credentials file ---------------------------------------------------

run_fence off-immediately off alpha
t_is "${RUN_RC}" "2" "no credentials file configured: exit 2"
t_like "${RUN_ERR}" 'SEANCE_FENCE_IPMI_CONF' \
    "no credentials file: names both ways to give one"
t_is "$( cat "${RUN_LOG}" )" "" "no credentials file: ipmitool is never called"

run_fence off-immediately off alpha --config "${FIX}/nope"
t_is "${RUN_RC}" "2" "missing credentials file: exit 2"
t_like "${RUN_ERR}" 'does not exist' "missing credentials file: says so"

# The environment variable is the path seance's promote will use.
d=$( t_tmpdir )
: > "${d}/log"
SEANCE_FENCE_IPMI_CONF="${FIX}/conf" FENCE_SHIM_MODE=off-immediately \
    FENCE_SHIM_LOG="${d}/log" FENCE_SHIM_STATE="${d}/state" \
    "${DRIVER}" status alpha > "${d}/out" 2> "${d}/err"
rc=$?
t_is "${rc}" "0" "SEANCE_FENCE_IPMI_CONF is honoured"
t_is "$( cat "${d}/out" )" "fence_ipmi: alpha off power is off" \
    "SEANCE_FENCE_IPMI_CONF: the verdict line is the same"

# SEANCE_FENCE_TIMEOUT is the other half of that: seance passes the site's
# fence_timeout through the environment and the driver must obey it.
d=$( t_tmpdir )
: > "${d}/log"
t0=$( date +%s )
SEANCE_FENCE_TIMEOUT=2 FENCE_SHIM_MODE=hang FENCE_SHIM_LOG="${d}/log" \
    FENCE_SHIM_STATE="${d}/state" \
    "${DRIVER}" off alpha --config "${FIX}/conf" > "${d}/out" 2> "${d}/err"
rc=$?
elapsed=$(( $( date +%s ) - t0 ))
t_is "${rc}" "2" "SEANCE_FENCE_TIMEOUT is honoured"
if [ "${elapsed}" -lt 10 ]; then
    t_ok "SEANCE_FENCE_TIMEOUT: gave up in ${elapsed}s"
else
    t_not_ok "SEANCE_FENCE_TIMEOUT: took ${elapsed}s, wanted under 10"
fi

# --- permissions ------------------------------------------------------------

for mode in 644 640 604 660 606; do
    fix=$( mkfix )
    chmod "${mode}" "${fix}/conf"
    run_fence off-immediately off alpha --config "${fix}/conf"
    t_is "${RUN_RC}" "2" "credentials file mode ${mode}: refused with exit 2"
    t_like "${RUN_ERR}" 'readable beyond its owner' \
        "credentials file mode ${mode}: says why"
    t_is "$( cat "${RUN_LOG}" )" "" \
        "credentials file mode ${mode}: ipmitool is never called"
done

fix=$( mkfix )
chmod 400 "${fix}/conf"
run_fence off-immediately off alpha --config "${fix}/conf"
t_is "${RUN_RC}" "0" "credentials file mode 400: narrower than 0600 is fine"

fix=$( mkfix )
chmod 644 "${fix}/pass"
run_fence off-immediately off alpha --config "${fix}/conf"
t_is "${RUN_RC}" "2" "passfile mode 644: refused with exit 2"
t_like "${RUN_ERR}" 'readable beyond its owner' "passfile mode 644: says why"
t_is "$( cat "${RUN_LOG}" )" "" "passfile mode 644: ipmitool is never called"

fix=$( mkfix )
rm -f "${fix}/pass"
run_fence off-immediately off alpha --config "${fix}/conf"
t_is "${RUN_RC}" "2" "missing passfile: exit 2"
t_like "${RUN_ERR}" 'does not exist' "missing passfile: says so"

fix=$( mkfix )
rm -f "${fix}/pass"
mkdir "${fix}/pass"
run_fence off-immediately off alpha --config "${fix}/conf"
t_is "${RUN_RC}" "2" "passfile that is a directory: exit 2"
t_like "${RUN_ERR}" 'not a regular file' "passfile that is a directory: says so"

# --- the credentials grammar ------------------------------------------------
#
# The driver parses this file, it does not source it: a file that names how to
# power machines off is the last file that should be handed the shell. These
# rows are the same grammar rules lib/conf.subr enforces (D-30, D-31, D-32,
# D-34), re-asserted against the standalone implementation.

# conf_case <body> ... writes a conf with the given body and a good passfile.
conf_case()
{
    local _d

    _d=$( t_tmpdir )
    printf '%s\n' "${SECRET}" > "${_d}/pass"
    chmod 600 "${_d}/pass"
    cat > "${_d}/conf"
    chmod 600 "${_d}/conf"
    printf '%s\n' "${_d}"
}

d=$( conf_case <<CONF
target_alpha_host=alpha-bmc.example.net
target_alpha_user=fenceuser
target_alpha_pasfile=/dev/null
CONF
)
run_fence off-immediately off alpha --config "${d}/conf"
t_is "${RUN_RC}" "2" "grammar: an unknown key stops the load"
t_like "${RUN_ERR}" 'unknown key' "grammar: and says which"

d=$( conf_case <<CONF
target_alpha_host=alpha-bmc.example.net
target_alpha_host=other-bmc.example.net
target_alpha_user=fenceuser
CONF
)
run_fence off-immediately off alpha --config "${d}/conf"
t_is "${RUN_RC}" "2" "grammar: a duplicate key is an error"
t_like "${RUN_ERR}" 'duplicate key' "grammar: and says which"

d=$( t_tmpdir )
printf '%s\n' "${SECRET}" > "${d}/pass"
chmod 600 "${d}/pass"
printf 'target_alpha_host=alpha-bmc.example.net\r\ntarget_alpha_user=x\r\n' \
    > "${d}/conf"
chmod 600 "${d}/conf"
run_fence off-immediately off alpha --config "${d}/conf"
t_is "${RUN_RC}" "2" "grammar: a carriage return is an error, not whitespace"
t_like "${RUN_ERR}" 'carriage return' "grammar: and says so"

d=$( conf_case <<CONF
target_alpha_host alpha-bmc.example.net
CONF
)
run_fence off-immediately off alpha --config "${d}/conf"
t_is "${RUN_RC}" "2" "grammar: a line that is neither comment nor key=value"
t_like "${RUN_ERR}" 'not a comment and not key=value' "grammar: and says so"

d=$( conf_case <<CONF
target_alpha_host=alpha-bmc.example.net
target_alpha_passfile=/nonexistent
CONF
)
run_fence off-immediately off alpha --config "${d}/conf"
t_is "${RUN_RC}" "2" "grammar: an entry missing target_<name>_user is refused"
t_like "${RUN_ERR}" 'target_alpha_user is missing' "grammar: and names the key"

# Leading whitespace is stripped from the line, trailing whitespace from the
# value, '#' comments only at the start of a line (D-30, D-41).
d=$( t_tmpdir )
printf '%s\n' "${SECRET}" > "${d}/pass"
chmod 600 "${d}/pass"
{
    printf '   # an indented comment\n'
    printf '\n'
    printf '    target_alpha_host=alpha-bmc.example.net   \n'
    printf 'target_alpha_user=fenceuser\t\n'
    printf 'target_alpha_passfile=%s/pass\n' "${d}"
    printf 'target_alpha_extra=-C 17 # not a comment\n'
} > "${d}/conf"
chmod 600 "${d}/conf"
run_fence off-immediately status alpha --config "${d}/conf"
t_is "${RUN_RC}" "0" "grammar: indented comments and padded values parse"
t_like "$( cat "${RUN_LOG}" )" '-H alpha-bmc.example.net -U fenceuser ' \
    "grammar: trailing whitespace is trimmed off the value"
t_like "$( cat "${RUN_LOG}" )" '# not a comment' \
    "grammar: a '#' after a value is part of the value"

# --- the extra field may not smuggle in a credential ------------------------
#
# Everything else about these fixtures is valid -- a real 0600 passfile, a
# complete entry -- so the only reason left for the refusal is the extra field
# itself. A fixture that was broken in some second way would let this pass for
# a reason that had nothing to do with what it claims to test.

for bad in '-P hunter2' '-E' '-a' '-k somekey' '-f /etc/passwd' '-H elsewhere'
do
    d=$( mkfix_extra "${bad}" )
    run_fence off-immediately off alpha --config "${d}/conf"
    t_is "${RUN_RC}" "2" "extra '${bad}': refused with exit 2"
    t_like "${RUN_ERR}" 'may not (carry a credential option|override)' \
        "extra '${bad}': says which option and why"
    t_is "$( cat "${RUN_LOG}" )" "" "extra '${bad}': ipmitool is never called"
done

# The same fixture shape with a harmless extra still works, which is what makes
# the rows above evidence about the screening and not about the fixture.
d=$( mkfix_extra '-C 3' )
run_fence off-immediately off alpha --config "${d}/conf"
t_is "${RUN_RC}" "0" "extra '-C 3': a harmless extra is passed through"
t_like "$( cat "${RUN_LOG}" )" '\-C 3 chassis power off' \
    "extra '-C 3': and reaches ipmitool's argv"

# --- the timeout is real ----------------------------------------------------

run_fence hang off alpha --config "${FIX}/conf" --timeout 2
t_is "${RUN_RC}" "2" "hang: a BMC that never answers is 'cannot determine'"
if [ "${RUN_ELAPSED}" -lt 10 ]; then
    t_ok "hang: bounded by timeout(1), returned in ${RUN_ELAPSED}s"
else
    t_not_ok "hang: took ${RUN_ELAPSED}s, wanted under 10"
fi

# --- ipmitool absent --------------------------------------------------------
#
# A documented dependency that is not installed is a contract error, not a
# fence that quietly did nothing. /bin:/usr/bin is FreeBSD base, where the
# driver's other tools (stat, date, grep, sleep, timeout, mktemp, cut) live and
# ipmitool -- a port -- does not.

d=$( t_tmpdir )
: > "${d}/log"
PATH=/bin:/usr/bin FENCE_SHIM_MODE=off-immediately FENCE_SHIM_LOG="${d}/log" \
    "${DRIVER}" off alpha --config "${FIX}/conf" > "${d}/out" 2> "${d}/err"
rc=$?
t_is "${rc}" "2" "ipmitool absent: exit 2"
t_like "$( cat "${d}/err" )" 'ipmitool not found' "ipmitool absent: says so"
t_like "$( cat "${d}/out" )" '^fence_ipmi: alpha unknown ' \
    "ipmitool absent: still prints a verdict line"

t_done
