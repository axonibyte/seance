#!/bin/sh
# Tier 7, stage 'sim' -- simulated cluster life (TESTING.md §7, DESIGN.md).
#
# The tier's entry point. It does three things, in this order, and the order is
# the point:
#
#   1. THE ORACLE SELF-TEST FIRST. tests/tier4/t_sim_oracle_selftest.sh feeds
#      the invariants hand-built broken states and requires every one of them
#      to fire. An invariant that cannot fire is indistinguishable from a
#      passing suite, so a session is not spent on the expensive tier until the
#      cheap check that the expensive tier means something has passed. If it
#      fails, this file stops there and says so.
#
#   2. THE FIXED BATTERY. Every seed in tests/cluster/sim/seeds.txt, each for
#      SEANCE_SIM_STEPS events against a freshly built pseudo-cluster. One
#      assertion per seed, because a battery that reported one verdict for five
#      seeds would tell nobody which one to replay.
#
#   3. HUNTING, opt-in (SEANCE_HUNT=1, `reaper run --profile hunt`). Seeds
#      drawn from /dev/urandom and printed, for as long as SEANCE_HUNT_BUDGET
#      seconds allow.
#
# AND A BOUNDED HUNT THAT DOES NOT PAY FOR THE BATTERY FIRST (D-162): with
# SEANCE_HUNT_ONLY=1 beside SEANCE_HUNT=1, step 2 is skipped and step 1 is not.
# The battery is 2 h 45 m (D-142), so a hunt behind it cannot be reached inside
# a session that was meant for hunting; and the obvious shortening --
# SEANCE_SIM_SEEDS with one seed -- switches the nominations off for the whole
# run, so a hunt driven that way reports what it found in a diagnostic and
# nowhere else. THE ORACLE SELF-TEST IS NEVER SKIPPED: a hunt with a broken
# oracle is not a cheap hunt, it is noise. Every switch and every nomination
# rule lives in tests/cluster/sim/hunt.subr, which a workstation can run --
# tests/tier1/t_sim_hunt.sh does.
#
# WHAT HAPPENS TO A SEED THAT FINDS SOMETHING. It is written to
# $REAPER_OUT/sim/seeds-to-promote.txt, and this file does NOT edit the
# committed battery (D-137). The promotion rule -- any seed that ever finds a
# defect joins seeds.txt permanently -- is a rule about defects, and this same
# runner is what the rediscovery battery drives with a protection deliberately
# reverted: a runner that appended on every failure would fill the battery with
# seeds that found a hole somebody made on purpose. Two things follow, and both
# are below: a run driven by SEANCE_SIM_SEEDS nominates nothing, and only a run
# that reached a VERDICT nominates at all -- a run killed before it could
# decide (run.sh's exit 3) is a fact about the session, not about the seed.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/stage.subr
. "${T_ROOT}/tests/cluster/lib/stage.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/sim/hunt.subr
. "${T_ROOT}/tests/cluster/sim/hunt.subr"

stage_begin sim

export SEANCE_ROOT="${T_ROOT}"

SIM_RUN="${T_ROOT}/tests/cluster/sim/run.sh"
SIM_SEEDS="${T_ROOT}/tests/cluster/sim/seeds.txt"
SIM_SELFTEST="${T_ROOT}/tests/tier4/t_sim_oracle_selftest.sh"

STEPS=${SEANCE_SIM_STEPS:-60}
HUNT_BUDGET=${SEANCE_HUNT_BUDGET:-3600}

# What this run is for, decided before anything expensive starts. A
# contradiction between the switches is a contract error and stops here rather
# than three hours from here.
if ! MODE=$( sim_hunt_mode ); then
    t_plan 1
    t_not_ok "the run's switches say what this run is for"
    t_diag "SEANCE_HUNT=[${SEANCE_HUNT:-}] SEANCE_HUNT_ONLY=[${SEANCE_HUNT_ONLY:-}]"
    t_done
fi

if [ "$( id -u )" -ne 0 ]; then
    t_diag "tier 7 builds jails and ZFS datasets; it needs root"
    echo "t_sim: must run as root" >&2
    exit 2
fi

# seeds  -- the committed battery, comments and blanks dropped.
#
# SEANCE_SIM_SEEDS overrides it with a list, which is what the rediscovery
# battery uses: a row there asserts that a REVERTED protection is noticed, and
# noticing it once is the whole answer -- five seeds would be four more cluster
# rebuilds for the same bit of information. It is not a way of shortening the
# default battery, and the diagnostic says which was run so that a green run
# cannot be mistaken for the battery when it was not.
seeds()
{
    if [ -n "${SEANCE_SIM_SEEDS:-}" ]; then
        printf '%s\n' "${SEANCE_SIM_SEEDS}" | tr ',' ' ' | tr ' ' '\n' |
            awk 'NF > 0 { print $1 }'
        return 0
    fi

    awk '/^[ \t]*#/ { next } NF > 0 { print $1 }' "${SIM_SEEDS}"
}

SEEDS=$( seeds )
NSEEDS=$( printf '%s\n' "${SEEDS}" | awk 'NF > 0 { n++ } END { print n + 0 }' )

if [ "${NSEEDS}" -eq 0 ]; then
    t_plan 1
    t_not_ok "the committed seed battery has seeds in it"
    t_diag "a battery with nothing in it costs a session and proves nothing"
    t_done
fi

t_plan "$( sim_plan "${MODE}" "${NSEEDS}" )"

# SAID BEFORE ANYTHING RUNS AND AGAIN AT THE END, because this is the line that
# stops a green hunt-only stage from being read as an acceptance run.
t_diag "$( sim_battery_banner "${MODE}" )"

if [ -n "${SEANCE_SIM_SEEDS:-}" ]; then
    t_diag "seeds from SEANCE_SIM_SEEDS, NOT the committed battery:" \
        "$( printf '%s' "${SEEDS}" | tr '\n' ' ' )"
fi

OUTDIR=${REAPER_OUT:-$( t_tmpdir )}
mkdir -p "${OUTDIR}/sim" 2>/dev/null || true

# WHERE THE NOMINATIONS GO, and when there are none to make.
#
# The file names the seeds THIS run found something with, so it starts empty:
# it was append-only, and a session that ran the battery and then the three
# tier-7 rediscovery rows left a list of nine nominations from five seeds, four
# of which were the one seed the rediscovery rows are pinned to (D-143) failing
# because a protection had been reverted on purpose.
#
# And a run driven by SEANCE_SIM_SEEDS makes no nominations at all. That is
# D-137's own argument -- a runner that nominated on every failure would fill
# the permanent battery with seeds that found a hole somebody made on purpose
# -- applied one file earlier than D-137 applied it, because the file is what a
# person reads when deciding.
PROMOTE=$( sim_promote_file "${OUTDIR}/sim" )

# ---------------------------------------------------------------------------
# 1. The oracle self-test
# ---------------------------------------------------------------------------

SELF="${OUTDIR}/sim/oracle-selftest.log"
sh "${SIM_SELFTEST}" > "${SELF}" 2>&1
SELF_RC=$?

if [ "${SELF_RC}" -eq 0 ]; then
    t_ok "the oracle self-test passes: every invariant was seen firing"
else
    t_not_ok "the oracle self-test passes: every invariant was seen firing"
    t_diag "exit ${SELF_RC}; tier 7 will not be run against a checker that cannot fire"
    sed -e 's/^/# /' "${SELF}" | tail -30
    t_done
fi

# ---------------------------------------------------------------------------
# 2. The fixed battery
# ---------------------------------------------------------------------------

# run_seed <seed>  -- rc 0 when the seed passed. Its whole output is kept.
run_seed()
{
    local _seed _log _rc _t0 _t1

    _seed=$1
    _log="${OUTDIR}/sim/${_seed}.log"

    _t0=$( date +%s )
    env SEANCE_SEED="${_seed}" SEANCE_SIM_STEPS="${STEPS}" \
        SEANCE_ROOT="${T_ROOT}" sh "${SIM_RUN}" > "${_log}" 2>&1
    _rc=$?
    _t1=$( date +%s )

    t_diag "seed ${_seed}: ${STEPS} steps, exit ${_rc}, $(( _t1 - _t0 ))s"

    if [ "${_rc}" -ne 0 ]; then
        awk '/FIRED|^sim: FAILED|^shrink: |^world: FAIL|^sim: FAIL|^sim: ABORTED/ { print "# " $0 }' \
            "${_log}" | head -40
    fi

    # ONLY A RUN THAT REACHED A VERDICT NOMINATES A SEED. run.sh exits 1 when
    # an invariant fired, 2 when the driver could not run and 3 when it was
    # killed before it could decide (its own header says so); the last two are
    # facts about the session, not about the seed, and a seed nominated by one
    # of them sends the next person hunting a defect that was never there.
    # The assertion is unchanged: anything but 0 still fails the seed's row.
    if sim_nominates "${_rc}"; then
        [ -z "${PROMOTE}" ] ||
            printf '%s\t# found a defect on %s; naming it is the fixer'"'"'s job\n' \
                "${_seed}" "$( date -u +%Y-%m-%d )" >> "${PROMOTE}" 2>/dev/null
    elif [ "${_rc}" -ne 0 ]; then
        t_diag "seed ${_seed}: exit ${_rc} is the run failing, not the seed" \
            "finding something -- it is NOT nominated for the battery"
    fi

    return "${_rc}"
}

if sim_runs_battery "${MODE}"; then
    BATTERY_T0=$( date +%s )

    for seed in ${SEEDS}; do
        if run_seed "${seed}"; then
            t_ok "seed ${seed} survived ${STEPS} events with every invariant intact"
        else
            t_not_ok "seed ${seed} survived ${STEPS} events with every invariant intact"
        fi
    done

    BATTERY_T1=$( date +%s )
    t_diag "the default battery took $(( BATTERY_T1 - BATTERY_T0 ))s" \
        "(${NSEEDS} seeds x ${STEPS} steps)"
else
    t_diag "the ${NSEEDS} committed seed(s) were NOT run: $( sim_battery_banner "${MODE}" )"
fi

# ---------------------------------------------------------------------------
# 3. Hunting
# ---------------------------------------------------------------------------

if sim_hunts "${MODE}"; then
    hunt_found=""
    hunt_seeds=0
    hunt_t0=$( date +%s )

    while :; do
        now=$( date +%s )
        [ $(( now - hunt_t0 )) -lt "${HUNT_BUDGET}" ] || break

        hseed=$( od -An -N4 -tu4 < /dev/urandom | tr -d ' \n' )
        [ -n "${hseed}" ] || break
        hunt_seeds=$(( hunt_seeds + 1 ))
        t_diag "hunting: seed ${hseed}"

        if ! run_seed "${hseed}"; then
            hunt_found="${hunt_found} ${hseed}"
        fi
    done

    t_diag "hunted ${hunt_seeds} seed(s) in $(( $( date +%s ) - hunt_t0 ))s"

    # The battery's fate is IN the hunt's assertion text, not only in a
    # diagnostic beside it: this is the line a summary quotes.
    if [ -z "${hunt_found}" ]; then
        t_ok "$( sim_battery_banner "${MODE}" ) -- the hunt found no defect in ${hunt_seeds} seed(s)"
    else
        t_not_ok "$( sim_battery_banner "${MODE}" ) -- the hunt found no defect in ${hunt_seeds} seed(s)"
        t_diag "seeds that found something:${hunt_found}"
        if [ -n "${PROMOTE}" ]; then
            t_diag "they are in ${PROMOTE}; the fix commits them to seeds.txt"
        else
            t_diag "this run was told which seeds to use, so it nominated nothing (D-137)"
        fi
    fi
fi

t_diag "$( sim_battery_banner "${MODE}" )"

t_done
