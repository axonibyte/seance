#!/bin/sh
# Tier 1 -- what a tier-7 run is for, and what it may nominate
# (tests/cluster/sim/hunt.subr).
#
# THE OPEN ITEM THIS FILE CLOSES (D-162). `SEANCE_HUNT=1` ran the committed
# battery first, and the battery is 2 h 45 m (D-142), so a forty-minute hunt
# could not be reached inside a session that was meant for hunting. The obvious
# shortening -- `SEANCE_SIM_SEEDS=<one seed>` -- silently switched the
# nominations off for the whole run (D-137), so a hunt driven that way reported
# what it found in a diagnostic line and nowhere a person would look. D-162
# said what a fix would look like and why it was not made: "the nomination
# decision lives inside a file that needs root and builds clusters, so testing
# it honestly means moving the decision into something sourceable".
#
# So the decisions moved, and this is the file that could not exist before:
# every switch, every plan count, every nomination rule, asserted on a
# workstation in milliseconds, with no cluster and no root.
#
# THE CALLER IS THE ENVIRONMENT (TESTING.md §0). A tier-7 run is started by
# `reaper run --profile hunt` or by a person typing environment variables in
# front of tests/run.sh; both reach the code as exactly these variables and
# nothing else, which is how they are set here -- one `env` per case, with the
# whole environment stated.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/sim/hunt.subr
. "${T_ROOT}/tests/cluster/sim/hunt.subr"

WORK=$( t_tmpdir )

t_plan 28

# mode <SEANCE_HUNT> <SEANCE_HUNT_ONLY>  -- the mode those two switches select,
# or "rc<n>" when they are refused. Run in a child shell with exactly those two
# variables, because that is how a profile delivers them.
mode()
{
    local _out _rc

    _out=$( env SEANCE_HUNT="$1" SEANCE_HUNT_ONLY="$2" SEANCE_SIM_SEEDS="" \
        sh -c ". \"${T_ROOT}/tests/cluster/sim/hunt.subr\"; sim_hunt_mode" \
        2> "${WORK}/mode.err" )
    _rc=$?

    if [ "${_rc}" -ne 0 ]; then
        printf 'rc%s\n' "${_rc}"
        return 0
    fi

    printf '%s\n' "${_out}"
}

# --- the switch table -------------------------------------------------------

t_is "$( mode "" "" )" "battery" \
    "with neither switch set, a tier-7 run is the committed battery"
t_is "$( mode 0 0 )" "battery" \
    "and both switches off is the same thing said out loud"
t_is "$( mode 1 "" )" "battery-hunt" \
    "SEANCE_HUNT=1 is the battery and then a hunt, exactly as before"
t_is "$( mode 1 0 )" "battery-hunt" \
    "and saying SEANCE_HUNT_ONLY=0 beside it changes nothing"
t_is "$( mode 1 1 )" "hunt-only" \
    "SEANCE_HUNT_ONLY=1 with SEANCE_HUNT=1 is a hunt with no battery (D-162)"

t_is "$( mode "" 1 )" "rc2" \
    "SEANCE_HUNT_ONLY=1 on its own is a CONTRACT ERROR, not a guess"
t_like "$( cat "${WORK}/mode.err" )" 'SEANCE_HUNT_ONLY=1 needs SEANCE_HUNT=1' \
    "and says which other switch it needs -- the two readings are three hours apart"

t_is "$( mode yes "" )" "rc2" \
    "SEANCE_HUNT=yes is refused rather than read as off"
t_like "$( cat "${WORK}/mode.err" )" 'SEANCE_HUNT must be 0 or 1' \
    "and names the variable and the value, because a session is what a wrong guess costs"
t_is "$( mode 1 yes )" "rc2" "SEANCE_HUNT_ONLY=yes is refused too"
t_like "$( cat "${WORK}/mode.err" )" 'SEANCE_HUNT_ONLY must be 0 or 1' \
    "and names that one"

# --- what each mode does ----------------------------------------------------

t_rc 0 "the battery mode runs the battery" -- sim_runs_battery battery
t_rc 1 "and hunts for nothing" -- sim_hunts battery
t_rc 0 "battery-hunt runs the battery" -- sim_runs_battery battery-hunt
t_rc 0 "and hunts after it" -- sim_hunts battery-hunt
t_rc 1 "hunt-only does NOT run the battery" -- sim_runs_battery hunt-only
t_rc 0 "and hunts" -- sim_hunts hunt-only

# The oracle self-test is not a mode's to skip: it is one assertion in every
# plan below, which is the arithmetic form of "never skipped".
t_is "$( sim_plan battery 5 )" "6" \
    "the battery plans one assertion per seed, plus the oracle self-test"
t_is "$( sim_plan battery-hunt 5 )" "7" \
    "hunting after it plans one more for the hunt"
t_is "$( sim_plan hunt-only 5 )" "2" \
    "and a hunt-only run plans the oracle self-test and the hunt, and no seed at all"

# --- the battery's fate is stated, loudly -----------------------------------

t_like "$( sim_battery_banner hunt-only )" 'DID NOT RUN' \
    "a hunt-only run says the battery DID NOT RUN, so a green stage cannot be read as one"
t_unlike "$( sim_battery_banner battery )" 'DID NOT RUN' \
    "and a run that did run it does not say that"

# --- nominations: unchanged by any of the above (D-137, D-147) --------------

t_rc 0 "exit 1 -- an invariant fired -- nominates the seed" -- sim_nominates 1
t_rc 1 "exit 3 -- the run was killed -- does NOT: that is a fact about the session (D-147)" \
    -- sim_nominates 3

NOMDIR="${WORK}/out"
mkdir -p "${NOMDIR}"
printf 'stale\n' > "${NOMDIR}/seeds-to-promote.txt"

FILE=$( env SEANCE_SIM_SEEDS="" sh -c \
    ". \"${T_ROOT}/tests/cluster/sim/hunt.subr\"; sim_promote_file \"${NOMDIR}\"" )
if [ "${FILE}" = "${NOMDIR}/seeds-to-promote.txt" ] &&
   [ ! -s "${FILE}" ]; then
    t_ok "a run that draws its own seeds gets a nomination file, truncated to this run's findings"
else
    t_not_ok "a run that draws its own seeds gets a nomination file, truncated to this run's findings"
    t_diag "got [${FILE}], contents [$( cat "${NOMDIR}/seeds-to-promote.txt" 2>&1 )]"
fi

printf 'stale\n' > "${NOMDIR}/seeds-to-promote.txt"
FILE=$( env SEANCE_SIM_SEEDS=2950315648 sh -c \
    ". \"${T_ROOT}/tests/cluster/sim/hunt.subr\"; sim_promote_file \"${NOMDIR}\"" )
if [ -z "${FILE}" ] && [ "$( cat "${NOMDIR}/seeds-to-promote.txt" )" = "stale" ]; then
    t_ok "a run told which seeds to use nominates nothing, and does not even open the file"
else
    t_not_ok "a run told which seeds to use nominates nothing, and does not even open the file"
    t_diag "got [${FILE}], contents [$( cat "${NOMDIR}/seeds-to-promote.txt" 2>&1 )]"
fi

# --- and the runner really is wired to all of it ----------------------------
#
# tests/tier7/t_sim.sh needs root and builds a cluster, but it decides what the
# run is for BEFORE either -- so the one thing this tier can prove about it,
# it proves: a contradiction is refused where it costs nothing.
SIMOUT="${WORK}/tsim.out"
env SEANCE_HUNT_ONLY=1 SEANCE_HUNT=0 SEANCE_STAGES=sim \
    sh "${T_ROOT}/tests/tier7/t_sim.sh" > "${SIMOUT}" 2>&1
SIM_RC=$?

t_isnt "${SIM_RC}" "0" \
    "the tier-7 runner refuses contradictory switches before it needs root or a cluster"
t_like "$( cat "${SIMOUT}" )" 'SEANCE_HUNT=\[0\] SEANCE_HUNT_ONLY=\[1\]' \
    "and prints both switches as it received them"

t_done
