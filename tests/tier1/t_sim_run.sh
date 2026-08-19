#!/bin/sh
# Tier 1 -- the tier-7 driver's own contract (tests/cluster/sim/run.sh).
#
# Two properties, both about what a RUN says about itself rather than about
# what the cluster did, and both testable on a workstation because a dry run
# needs no cluster (SEANCE_SIM_DRY, D-135).
#
# 1. A SEED IS A TRACE. The same seed deals the same fleet and the same events,
#    every time. It is the assumption the whole tier rests on -- the fixed
#    battery, the shrinker's reruns and D-143's pinned rediscovery windows all
#    read "seed 2950315648, 27 steps" as the name of one particular trace -- and
#    it was never asserted anywhere.
#
# 2. A RUN THAT WAS KILLED SAYS SO. The harness's signal trap exits 1, which is
#    also what an invariant firing exits with, so an interrupted battery used to
#    be indistinguishable from a battery that found five defects -- and on
#    2026-08-17 it was read as exactly that. run.sh now prints its own verdict
#    line and exits 3 instead, and tests/tier7/t_sim.sh nominates a seed for the
#    permanent battery only on exit 1.
#
# The kill tests run a dry trace far longer than they wait for, so the signal
# always arrives mid-run; each of them waits on the child rather than sleeping
# for a fixed time, so a slow machine costs seconds and never a false verdict.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

t_plan 11

RUN="${T_ROOT}/tests/cluster/sim/run.sh"
WORK=$( t_tmpdir )

# --- 1. the same seed deals the same trace ----------------------------------

dry()
{
    env SEANCE_SIM_DRY=1 SEANCE_SEED="$1" SEANCE_SIM_STEPS="$2" \
        SEANCE_ROOT="${T_ROOT}" REAPER_OUT= sh "${RUN}" 2>/dev/null
}

dry 2950315648 12 > "${WORK}/a" 2>&1
t_is "$?" "0" "a dry run of a committed battery seed exits 0"

dry 2950315648 12 > "${WORK}/b" 2>&1
t_is "$?" "0" "the same dry run, again, exits 0"

if cmp -s "${WORK}/a" "${WORK}/b"; then
    t_ok "the same seed deals the same fleet and the same twelve events"
else
    t_not_ok "the same seed deals the same fleet and the same twelve events"
    t_diag "$( diff -u "${WORK}/a" "${WORK}/b" | head -20 )"
fi

dry 1043489862 12 > "${WORK}/c" 2>&1
if cmp -s "${WORK}/a" "${WORK}/c"; then
    t_not_ok "a different seed deals a different trace"
    t_diag "two seeds produced byte-identical traces; the stream is not seeded"
else
    t_ok "a different seed deals a different trace"
fi

# The prefix property the shrinker and D-143 both rely on: asking for fewer
# steps of one seed gives the FIRST steps of that seed, not a different trace.
# Seven lines: the seed, the fleet, and the five events -- everything the
# shorter run has except its own verdict line.
dry 2950315648 5 > "${WORK}/d" 2>&1
head -7 "${WORK}/a" > "${WORK}/a7"
head -7 "${WORK}/d" > "${WORK}/d7"
if cmp -s "${WORK}/a7" "${WORK}/d7"; then
    t_ok "a shorter run of one seed is the longer run's first steps"
else
    t_not_ok "a shorter run of one seed is the longer run's first steps"
    t_diag "$( diff -u "${WORK}/d" "${WORK}/a" | head -20 )"
fi

# --- 2. a run that was killed says so ---------------------------------------

# kill_run <signal>  -- start a long dry run, signal it once it is past its
# first event, and leave its output in $WORK/killed and its status in KILL_RC.
KILL_RC=""
kill_run()
{
    local _sig _pid _i

    _sig=$1
    : > "${WORK}/killed"

    env SEANCE_SIM_DRY=1 SEANCE_SEED=2950315648 SEANCE_SIM_STEPS=100000 \
        SEANCE_ROOT="${T_ROOT}" REAPER_OUT= sh "${RUN}" \
        > "${WORK}/killed" 2>&1 &
    _pid=$!

    # Wait for it to be genuinely under way rather than sleeping a fixed time:
    # the run has started when its first event is on stdout.
    _i=0
    while [ "${_i}" -lt 100 ]; do
        grep -q '^1 ' "${WORK}/killed" && break
        _i=$(( _i + 1 ))
        sleep 0.1
    done

    kill -"${_sig}" "${_pid}" 2>/dev/null
    wait "${_pid}"
    KILL_RC=$?
}

kill_run TERM
t_is "${KILL_RC}" "3" "a run killed with TERM exits 3, not 1"
t_like "$( cat "${WORK}/killed" )" '^sim: ABORTED on TERM at step [0-9]' \
    "and prints a verdict line naming the signal and the step"
t_like "$( cat "${WORK}/killed" )" '^sim: ABORTED .* seed 2950315648: killed' \
    "and names the seed in it, so the log is self-identifying"
t_unlike "$( cat "${WORK}/killed" )" '^sim: (PASS|DRY|FAILED)' \
    "and claims neither a pass nor a finding"

# INT IS NOT TESTED HERE, and the reason is the harness rather than the trap.
# A shell that starts a job with '&' and has no job control sets SIGINT (and
# SIGQUIT) to SIG_IGN in that job -- sh(1), "Background Commands", and POSIX
# 2.11 -- so a test cannot deliver one to a background run at all. INT is
# trapped for the person who types ^C at a terminal; TERM and HUP are what a
# battery driven over ssh actually dies of, and those are asserted.

kill_run HUP
t_is "${KILL_RC}" "3" "a run whose terminal hangs up exits 3"
t_like "$( cat "${WORK}/killed" )" '^sim: ABORTED on HUP ' \
    "and says HUP -- which is how a battery driven over ssh dies"

t_done
