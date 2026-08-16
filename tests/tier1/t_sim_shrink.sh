#!/bin/sh
# Tier 1 -- the tier-7 shrinker (tests/cluster/sim/shrink.subr).
#
# A seed tells you a bug exists; a trace tells you what it is. The shrinker is
# the thing that turns a sixty-step trace into something a person reads, and
# it is testable without a cluster because the only thing it does with the
# world is call one injected function.
#
# The fake rerun below fails on exactly two conditions -- the run reached step
# 7, and neither 'tick' nor 'promote' was skipped -- so the correct reduction
# is known in advance and can be asserted rather than eyeballed: seven steps,
# with kill, heal and isolate removed and nothing else.
#
# The rerun count is asserted too, and deliberately to the exact number. The
# shrinker's value is that it is cheap: on a real seed each rerun rebuilds a
# cluster, so a bisection quietly degrading into a linear scan is a defect
# that would never show up as a wrong answer, only as a session that ran out
# of time. Twelve steps costs 1 reproduction + 3 bisection reruns (mid 6 passes,
# mid 9 fails, mid 7 fails) + 5 kind reruns = 9; a linear scan would cost 18.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/sim/shrink.subr
. "${T_ROOT}/tests/cluster/sim/shrink.subr"

t_plan 15

WORK=$( t_tmpdir )
TRACE="${WORK}/trace"
CALLS="${WORK}/calls"

cat > "${TRACE}" <<'EOF'
# seed 20260816
1 tick
2 kill alpha
3 tick
4 heal alpha
5 isolate bravo
6 tick
7 promote alpha bravo
8 flap charlie
9 tick
10 skew charlie
11 tick
12 hostile-snap bravo ghost01
EOF

# --- the trace readers ------------------------------------------------------

t_is "$( shrink_steps "${TRACE}" )" 12 \
    "shrink_steps counts events and ignores the '# seed' line"

t_is "$( shrink_kinds "${TRACE}" 7 "" | tr '\n' ' ' )" \
    "tick kill heal isolate promote " \
    "shrink_kinds lists the prefix's kinds in first-appearance order"

t_is "$( shrink_kinds "${TRACE}" 7 "kill,heal" | tr '\n' ' ' )" \
    "tick isolate promote " \
    "shrink_kinds drops kinds already skipped"

t_is "$( shrink_trace "${TRACE}" 7 "kill,heal,isolate" | wc -l | tr -d ' ' )" 4 \
    "shrink_trace applies both the step limit and the skip list"

# --- the contract before anything is injected -------------------------------

t_rc 2 "shrink_run refuses when no shrink_rerun function is defined" \
    -- shrink_run "${TRACE}"

# --- the fake world ---------------------------------------------------------

: > "${CALLS}"

# in_list <word> <comma-list>
in_list()
{
    local _i _l

    _l=$2
    IFS=,
    for _i in ${_l}; do
        if [ "${_i}" = "$1" ]; then
            unset IFS
            return 0
        fi
    done
    unset IFS

    return 1
}

# shrink_rerun <steps> <skip-kinds> -- the injected world.
#
# Fails (rc 1) only when the run is long enough to have reached step 7 and
# both of the kinds that actually matter are still being dealt.
shrink_rerun()
{
    printf '%s %s\n' "$1" "${2:-}" >> "${CALLS}"

    [ "$1" -ge 7 ] || return 0
    in_list tick "${2:-}" && return 0
    in_list promote "${2:-}" && return 0

    return 1
}

# Not 'OUT=$( shrink_run ... )': shrink_run reports its answer in SHRINK_STEPS
# and SHRINK_SKIP as well as on stdout, and a command substitution is a
# subshell, so the globals would come back untouched and the assertions below
# would be reading their initial values.
shrink_run "${TRACE}" > "${WORK}/out" 2> "${WORK}/err"
RC=$?
OUT=$( cat "${WORK}/out" )

t_is "${RC}" 0 "shrink_run reduces a reproducing failure"
t_is "${SHRINK_STEPS}" 7 "the minimal failing prefix is found, not merely a failing one"
t_is "${SHRINK_SKIP}" "kill,heal,isolate" \
    "exactly the uninvolved kinds are removed"

t_like "${OUT}" '^shrink: kind tick: involved' \
    "an involved kind is named as involved, not removed"
t_like "${OUT}" '^shrink: kind promote: involved' \
    "the second involved kind is named as involved too"
t_like "${OUT}" 'freshly built cluster' \
    "the report says plainly that a non-reproduction is a weak signal"

REDUCED=$( printf '%s\n' "${OUT}" | sed -n '/^shrink: reduced trace/,$p' |
    grep -v '^shrink: ' )
t_is "$( printf '%s\n' "${REDUCED}" | grep -cE ' (kill|heal|isolate) ?' )" 0 \
    "the reduced trace holds none of the removed kinds"
t_is "$( printf '%s\n' "${REDUCED}" | grep -c 'promote' )" 1 \
    "the reduced trace still holds the event that matters"

t_is "$( wc -l < "${CALLS}" | tr -d ' ' )" 9 \
    "the reduction costs 9 reruns (bisection), not 18 (a linear scan)"

# --- the honest non-reproduction --------------------------------------------

shrink_rerun()
{
    printf '%s %s\n' "$1" "${2:-}" >> "${CALLS}"
    return 0
}

OUT=$( shrink_run "${TRACE}" 2>&1 )
RC=$?
if [ "${RC}" -eq 1 ] &&
    printf '%s\n' "${OUT}" | grep -q '^shrink: did not reproduce'; then
    t_ok "a trace that passes on rerun is reported, not shrunk to one step"
else
    t_not_ok "a trace that passes on rerun is reported, not shrunk to one step"
    t_diag "rc: ${RC}"
    printf '%s\n' "${OUT}" | sed -e 's/^/# out: /'
fi

t_done
