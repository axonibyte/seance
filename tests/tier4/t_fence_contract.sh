#!/bin/sh
# Tier 4 -- the fence driver's contract, fuzzed.
#
# The fence rung is the one place in seance where another program's exit status
# is a licence to start a guest somewhere else. tests/tier4/ladder.tsv crosses
# the six answers a well-behaved driver gives with --force; this file asks what
# happens for the answers nobody designed: every exit status from 0 to 255,
# output that is binary, output that is a web server's error page, output that
# is two hundred lines, a driver that answers far too late, and a target string
# with a semicolon in it.
#
# THE RULE BEING ASSERTED (D-44 item 2, D-68), and it is exactly three lines:
#
#   rc 0 and it said something   -> verified off. Promotion may proceed.
#   rc 1                          -> refused / still on. Hard abort, and NOT
#                                    forceable, ever: a fence that failed and a
#                                    host that answers are the two situations
#                                    where forcing is the split brain.
#   anything else                 -> CANNOT DETERMINE. Notify; forceable, and
#                                    what --force overrides is exactly this.
#
# "Anything else" is where the fuzz earns its keep: 254 of the 256 possible
# exit statuses land there, and every one of them must land there by the rule
# rather than by a case label somebody remembered to write. rc 0 with nothing
# on stdout is a contract violation and is read as CANNOT DETERMINE -- the
# crashed-verifier class (TESTING.md §5), applied to the one command whose
# success starts a guest.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

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
# shellcheck source=../mock-adapter.subr
. "${T_ROOT}/tests/mock-adapter.subr"

DIR=$( t_tmpdir )

SEANCE_ROOT="${DIR}/root"
export SEANCE_ROOT
mkdir -p "${SEANCE_ROOT}/drivers"

# --- the driver under test --------------------------------------------------
#
# Scripted by its OWN environment, never by seance's: a code path only the
# tests take is a code path nobody else exercises (D-35, D-76).
cat > "${SEANCE_ROOT}/drivers/fence_fuzz" <<'EOF'
#!/bin/sh
set -u
[ -n "${FUZZ_LOG:-}" ] && printf '%s|%s\n' "$1" "${2:-}" >> "${FUZZ_LOG}"

[ "${FUZZ_SLEEP:-0}" -gt 0 ] && sleep "${FUZZ_SLEEP}"

case "${FUZZ_OUT:-line}" in
    none)   ;;
    line)   printf 'fence_fuzz: %s %s done\n' "$1" "${2:-}" ;;
    multi)  awk 'BEGIN { while (i++ < 200) print "chatter line " i }' ;;
    binary) printf 'noise \001\002\010\177 more\n' ;;
    html)   printf '<html><head><title>500 Internal Server Error</title></head>\n' ;;
esac

exit "${FUZZ_RC:-0}"
EOF
chmod 0755 "${SEANCE_ROOT}/drivers/fence_fuzz"

# --- syslog, redirected ------------------------------------------------------
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

# --- one fleet, with a fence driver on the dead node ------------------------
CONF="${DIR}/seance.conf"
cat > "${CONF}" <<'EOF'
fence_timeout=1
node_alpha_nodename=alpha
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_alpha_fence_driver=fuzz
node_alpha_fence_target=alpha

node_bravo_nodename=bravo
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
EOF
conf_load "${CONF}" || { echo "the fixture configuration did not load" >&2; exit 2; }

SEANCE_STATE_DIR="${DIR}/state"
export SEANCE_STATE_DIR
mkdir -p "${SEANCE_STATE_DIR}"

PROMOTE_DEAD=alpha
PROMOTE_OPERATOR=fuzzer
PROMOTE_TMPDIR="${DIR}/promote"
mkdir -p "${PROMOTE_TMPDIR}"

FUZZ_LOG="${DIR}/fuzz.log"
export FUZZ_LOG

OUT="${DIR}/out"
ERR="${DIR}/err"

# fence <rc> <output-kind> [force]
#
# One run of rung 4, and its disposition. `pass` is the rung returning 0: it is
# the only branch that does not set PROMOTE_DISPOSITION, because the ladder
# goes on to rung 5 and the disposition is not yet decided.
D=""
RC=0
fence()
{
    FUZZ_RC=$1
    FUZZ_OUT=$2
    export FUZZ_RC FUZZ_OUT

    PROMOTE_FORCE=${3:-}
    PROMOTE_DISPOSITION=""
    PROMOTE_EVIDENCE=""

    promote_rung_fence > "${OUT}" 2> "${ERR}"
    RC=$?

    if [ "${RC}" -eq 0 ]; then
        D=pass
    else
        D=${PROMOTE_DISPOSITION:-NONE}
    fi
}

t_plan 22

# ---------------------------------------------------------------------------
# Every exit status from 0 to 255
# ---------------------------------------------------------------------------

PASSES="${DIR}/passes"
ABORTS="${DIR}/aborts"
NOTIFIES="${DIR}/notifies"
OTHER="${DIR}/other"
: > "${PASSES}"; : > "${ABORTS}"; : > "${NOTIFIES}"; : > "${OTHER}"

i=0
while [ "${i}" -le 255 ]; do
    fence "${i}" line
    case "${D}" in
        pass)   printf '%s\n' "${i}" >> "${PASSES}" ;;
        abort)  printf '%s\n' "${i}" >> "${ABORTS}" ;;
        notify) printf '%s\n' "${i}" >> "${NOTIFIES}" ;;
        *)      printf '%s %s\n' "${i}" "${D}" >> "${OTHER}" ;;
    esac
    i=$(( i + 1 ))
done

t_is "$( cat "${PASSES}" | tr '\n' ' ' )" "0 " \
    "exactly one exit status is a verified off, and it is 0"
t_is "$( cat "${ABORTS}" | tr '\n' ' ' )" "1 " \
    "exactly one is a hard abort, and it is 1 -- refused, or still on"
t_is "$( awk 'END { print NR }' "${NOTIFIES}" )" "254" \
    "and the other 254 are CANNOT DETERMINE: the rule is a rule, not a list of case labels"
t_is "$( cat "${OTHER}" )" "" \
    "no exit status leaves the rung without a disposition"

# The 254 are not a shrug. Every one of them is forceable, and 1 is not.
fence 137 line fence
t_is "${D}" "pass" \
    "a driver killed by a signal is CANNOT DETERMINE, which --force=fence overrides"
t_is "${PROMOTE_EVIDENCE}" "force:fuzzer" \
    "and the evidence recorded is the operator's name, never the driver's"

fence 1 line fence
t_is "${D}" "abort" \
    "a REFUSED fence aborts even when the operator named the fence rung (D-68)"
fence 1 line "quorum fence lineage kernel"
t_is "${D}" "abort" \
    "and a bare --force, which names every forceable rung, does not reach it either"

# ---------------------------------------------------------------------------
# What the driver says, when what it says is not a sentence
# ---------------------------------------------------------------------------

fence 0 none
t_is "${D}" "notify" \
    "rc 0 with nothing on stdout is a contract violation, read as CANNOT DETERMINE"
t_like "$( cat "${OUT}" )" 'exited 0 and printed nothing' \
    "and the rung says so in those words, so an operator can tell it from a refusal"

fence 0 html
t_is "${D}" "pass" \
    "rc 0 with an error page on stdout is still rc 0: seance does not parse driver prose"

fence 0 binary
t_is "${D}" "pass" "and neither control bytes nor high bytes change that"
t_is "$( awk 'END { print NR }' "${OUT}" )" "1" \
    "and the rung line survives them: one line in, one line out"

fence 0 multi
t_is "${D}" "pass" "two hundred lines of chatter is still a verified off"
t_is "$( awk 'END { print NR }' "${OUT}" )" "1" \
    "but the rung is ONE line: a driver cannot flood the transcript a human reads at 03:00"
t_like "$( cat "${OUT}" )" '\(\+199 more line\(s\) from the driver\)' \
    "and the lines it did not print are COUNTED, so nothing goes missing quietly"

# ---------------------------------------------------------------------------
# A driver that answers far too late
#
# fence_timeout is 1s in this fixture and the driver sleeps 5. The late answer
# is a verified off, and it must not arrive as one.
# ---------------------------------------------------------------------------

FUZZ_SLEEP=5
export FUZZ_SLEEP
START=$( date -u +%s )
fence 0 line
ELAPSED=$(( $( date -u +%s ) - START ))
FUZZ_SLEEP=0
export FUZZ_SLEEP

t_is "${D}" "notify" \
    "a driver that answers after the deadline is CANNOT DETERMINE, not a verified off"
if [ "${ELAPSED}" -le 4 ]; then
    t_ok "and the rung really was bounded: it returned in ${ELAPSED}s, not the driver's 5"
else
    t_not_ok "and the rung really was bounded: it returned in ${ELAPSED}s, not the driver's 5"
fi

# ---------------------------------------------------------------------------
# `status` is not consulted, and the target is not a shell string
# ---------------------------------------------------------------------------

# The contract has two actions and the ladder uses one. A driver whose `status`
# flaps -- off, then on again a second later -- cannot change a promotion,
# because the promotion never asks: `off`'s own verdict is the evidence, and
# asking twice would only create a second answer to disagree with.
t_is "$( awk -F '|' '$1 != "off"' "${FUZZ_LOG}" )" "" \
    "the ladder asks the driver to turn the node OFF and never asks it for status"

# A target with shell metacharacters in it. conf_check demands a single word,
# so a target with a space never loads at all; a target with a semicolon does,
# and it must reach the driver as one argument that nothing has evaluated.
CANARY="${DIR}/canary"
cat > "${DIR}/hostile.conf" <<EOF
fence_timeout=1
node_alpha_nodename=alpha
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_alpha_fence_driver=fuzz
node_alpha_fence_target=alpha;touch_${CANARY##*/}_\$(id)\`id\`
node_bravo_nodename=bravo
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
EOF
conf_load "${DIR}/hostile.conf" || t_diag "the hostile-target configuration did not load"

: > "${FUZZ_LOG}"
fence 0 line
t_is "${D}" "pass" "a target with shell metacharacters still runs the driver"
t_is "$( awk -F '|' 'NR == 1 { print $2 }' "${FUZZ_LOG}" )" \
    "alpha;touch_canary_\$(id)\`id\`" \
    "and it arrives as ONE argument, byte for byte, with nothing expanded"
CANARIES=0
for _c in "${DIR}"/canary*; do
    [ -e "${_c}" ] && CANARIES=$(( CANARIES + 1 ))
done
t_is "${CANARIES}" "0" \
    "and nothing in it was ever run: the driver is exec'd with an argv, never through a shell"

t_done
