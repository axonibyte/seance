#!/bin/sh
# Tier 1 -- pol_now, and the one environment variable that replaces the clock.
#
# tests/cluster/sim/DESIGN.md §2 makes wall time not part of tier 7's model:
# the simulator advances a virtual clock by one cadence per event and every
# seance invocation in the run is given it, so replication cadence and
# staleness are functions of the trace rather than of how fast the guest is.
# ${SEANCE_NOW} is that hook. Production never sets it.
#
# THE ROW THAT MATTERS is the malformed one. A hook that fell back to the real
# clock when it could not read its input would make a seeded run silently
# non-deterministic -- the shrinker would then be bisecting a trace that does
# not reproduce, and every hour it spent would be spent on nothing. So a
# SEANCE_NOW that is not an epoch is a contract error with no output, and the
# callers are asserted to notice.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/policy.subr
. "${T_ROOT}/lib/policy.subr"

t_plan 18

# --- unset: the real clock, and it is a plausible one ----------------------

unset SEANCE_NOW

REAL=$( pol_now )
t_rc 0 "with SEANCE_NOW unset, pol_now succeeds" -- pol_now
t_like "${REAL}" '^[0-9]+$' "and prints an epoch"

# The real clock, cross-checked against date(1) -- which pol_now is the only
# function in the policy engine allowed to call, so this is the one place the
# two can be compared at all. A second of slack, because two calls to a clock
# are two different instants.
NOW_DATE=$( date -u +%s )
DELTA=$(( REAL - NOW_DATE ))
[ "${DELTA}" -lt 0 ] && DELTA=$(( -DELTA ))
t_rc 0 "and it agrees with date -u +%s to within a second" -- \
    test "${DELTA}" -le 1

t_isnt "${REAL}" "0" "the real clock is not the epoch itself"

# --- set: SEANCE_NOW IS the clock ------------------------------------------

SEANCE_NOW=1000000000
export SEANCE_NOW
t_stdout_is "1000000000" "SEANCE_NOW replaces the clock" -- pol_now
t_rc 0 "and pol_now still succeeds" -- pol_now

SEANCE_NOW=0
t_stdout_is "0" "the epoch itself is a legal SEANCE_NOW" -- pol_now

SEANCE_NOW=4102444800
t_stdout_is "4102444800" "and so is a time past the 2038 rollover" -- pol_now

# Threading it through the policy engine is the whole point: a verb reads the
# clock once and hands the answer to the pure functions, so a fixed clock fixes
# every decision downstream of it.
SEANCE_NOW=1767225600
t_stdout_is "20260101T000000Z" \
    "and the fixed clock reaches the timestamp formatter" -- \
    pol_epoch_to_ts "$( pol_now )"

# And it reaches a CHILD process, which is not incidental: `repl` re-executes
# the dispatcher once per guest-peer pair under lockf(1) (D-62), so a clock the
# environment did not carry would be the real one in every locked pair.
# shellcheck disable=SC2016
#   The single quotes are the point: this is source text for the CHILD shell,
#   and expanding ${T_ROOT} here would resolve it in the parent instead --
#   which is the opposite of what the assertion is about.
t_stdout_is "1767225600" "and an exported SEANCE_NOW reaches a child process" -- \
    sh -c '. "${T_ROOT}/lib/policy.subr"; pol_now'

# --- unset again: the hook leaves nothing behind ---------------------------

unset SEANCE_NOW
t_like "$( pol_now )" '^[0-9]+$' "unsetting it puts the real clock back"

# --- malformed: a contract error, never a quiet fall back -------------------

for bad in "not-an-epoch" "12x" "-1" "1.5" "1000 " " 1000" "1,000"; do
    SEANCE_NOW=${bad}
    export SEANCE_NOW

    if out=$( pol_now 2>/dev/null ); then
        t_not_ok "SEANCE_NOW=[${bad}] is refused"
        t_diag "pol_now succeeded and printed [${out}]"
    elif [ -n "${out}" ]; then
        t_not_ok "SEANCE_NOW=[${bad}] is refused"
        t_diag "pol_now failed but still printed [${out}]"
    else
        t_ok "SEANCE_NOW=[${bad}] is refused, with no output"
    fi
done

unset SEANCE_NOW
t_done
