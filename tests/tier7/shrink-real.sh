#!/bin/sh
# Tier 7, OPT-IN -- the shrinker against a real failure.
#
#   env REAPER_STATE=/tank/state sh tests/tier7/shrink-real.sh
#
# NOT NAMED t_*.sh ON PURPOSE. tests/run.sh collects tests/tier<N>/t_*.sh, and
# this one costs the better part of an hour: a failing 27-step run, a prefix
# bisection whose every rerun rebuilds a three-node cluster, and then two
# reruns to prove the reduction. It is the check you run when you have changed
# the shrinker or the world driver, and the one the tier-7 README points at --
# not the one every session pays for.
#
# WHAT IT IS FOR. tests/tier1/t_sim_shrink.sh drives the shrinker against a
# scripted oracle: it proves the algorithm (bisection, accumulation, reproduce
# first) and it proves it in three seconds, with no cluster anywhere. What it
# cannot prove is that the shrinker is useful on a REAL failure -- that a trace
# a person would have to read gets shorter, that the reduction still fails, and
# that the events left in it are the ones the failure is about.
#
# So a real defect is injected: tests/rediscovery/promotion-without-fencing.patch,
# the August catalogue's own, applied to a scratch copy exactly as
# tests/rediscovery/run.sh applies it. The working tree is never touched.
#
# THE SEED AND THE WINDOW ARE THE ONES THE REDISCOVERY ROW USES (D-143):
# 2950315648 at 27 steps reaches a promotion that completes, which is where an
# unfenced promotion becomes visible to invariant 2. A window chosen any other
# way would be a window that might never reach the protection.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SEED=${SEANCE_SHRINK_SEED:-2950315648}
STEPS=${SEANCE_SHRINK_STEPS:-12}
PATCHFILE="${T_ROOT}/tests/rediscovery/promotion-without-fencing.patch"

# THE SHRINK BUDGET IS PART OF THIS CHECK. run.sh estimates a reduction at
# about fifteen times the failing run (a bisection plus a kind-removal pass,
# each rerun rebuilding a cluster) and prints the unreduced trace instead when
# the estimate does not fit SEANCE_SIM_SHRINK_BUDGET -- which is the right
# default for a battery that must not lose its session to a reduction nobody
# asked for, and is exactly what this file HAS asked for. Measured: the 27-step
# window costs 233 s to fail and 3495 s to reduce, so the default 1800 s
# refuses it. Twelve steps still reaches the promotion at step 5 that an
# unfenced ladder makes visible, and reduces inside the budget below.
SEANCE_SIM_SHRINK_BUDGET=${SEANCE_SIM_SHRINK_BUDGET:-3600}
export SEANCE_SIM_SHRINK_BUDGET

if [ "$( id -u )" -ne 0 ]; then
    echo "shrink-real: builds jails and ZFS datasets; it needs root" >&2
    exit 2
fi

if [ -z "${REAPER_STATE:-}" ] && [ -z "${SEANCE_CLUSTER_BASE:-}" ]; then
    echo "shrink-real: set REAPER_STATE (or SEANCE_CLUSTER_BASE); the" \
        "pseudo-cluster does not guess where it may write" >&2
    exit 2
fi

t_plan 15

OUTDIR=${REAPER_OUT:-$( t_tmpdir )}/shrink-real
mkdir -p "${OUTDIR}"

SCRATCH=$( t_tmpdir )/tree
mkdir -p "${SCRATCH}"

# The copy, and the defect. Two commands rather than one pipeline, exactly as
# tests/rediscovery/run.sh does it and for its reason: a create that failed
# into an extract that succeeded is the false pass this repository keeps
# finding.
ARCHIVE=$( t_tmpdir )/tree.tar
( cd "${T_ROOT}" && tar -cf "${ARCHIVE}" --exclude ./.git --exclude ./out . ) ||
    { t_diag "could not archive the tree"; }
( cd "${SCRATCH}" && tar -xf "${ARCHIVE}" ) ||
    { t_diag "could not unpack the tree"; }

t_rc 0 "the scratch copy carries the tier-7 driver" \
    -- test -r "${SCRATCH}/tests/cluster/sim/run.sh"

if ( cd "${SCRATCH}" && patch -p1 -s < "${PATCHFILE}" ); then
    t_ok "the promotion-without-fencing patch applied to the copy"
else
    t_not_ok "the promotion-without-fencing patch applied to the copy"
    t_diag "the protection it reverts has moved; the rest of this file is meaningless"
    t_done
fi

# The defect is in, and it is the one the patch names: rung 4 reports "fencing
# skipped" instead of calling promote_rung_fence. Asserted from the copy's own
# source, so that a patch which applied somewhere harmless cannot be mistaken
# for a defect injected.
t_rc 0 "and the copy's rung 4 says 'fencing skipped' instead of fencing" \
    -- grep -q 'fencing skipped' "${SCRATCH}/lib/promote.subr"
t_rc 1 "-- while the real tree still fences" \
    -- grep -q 'fencing skipped' "${T_ROOT}/lib/promote.subr"

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

LOG="${OUTDIR}/run.log"
T0=$( date +%s )
env SEANCE_SEED="${SEED}" SEANCE_SIM_STEPS="${STEPS}" \
    SEANCE_ROOT="${SCRATCH}" REAPER_OUT="${OUTDIR}" \
    sh "${SCRATCH}/tests/cluster/sim/run.sh" > "${LOG}" 2>&1
RC=$?
T1=$( date +%s )

t_diag "the patched run took $(( T1 - T0 ))s and exited ${RC}"

t_is "${RC}" "1" \
    "the patched run FAILS, and with exit 1 -- an invariant fired, rather than the run being killed (3) or unable to start (2)"

# WHICH invariant, and why it is not always the same one. A ladder that skips
# its fence leaves the target UP, so the guest really is running in two places
# and invariant 1 catches it as the split brain it is; where the target was
# already stopped, what is left is a promotion with no evidence and invariant 2
# catches that. Either is the protection being rediscovered, and requiring one
# of them by name would be a row that fails when the trace deals a different
# hand. Measured on this window: invariant 1, at the first promotion.
t_like "$( cat "${LOG}" )" 'invariant (1|2) FIRED' \
    "and an invariant fired: a guest in two places, or a promotion with no evidence"

# ---------------------------------------------------------------------------
# The reduction
# ---------------------------------------------------------------------------

t_like "$( cat "${LOG}" )" '^shrink: reruns land on a freshly built cluster' \
    "the shrinker ran, and says what a rerun is worth"
t_unlike "$( cat "${LOG}" )" '^shrink: did not reproduce' \
    "the unreduced failure reproduced first, which is what makes the reduction mean anything (D-58)"

REDUCED=$( awk '/^shrink: prefix: /{ print $NF }' "${LOG}" )
case "${REDUCED}" in
    ''|*[!0-9]*)
        t_not_ok "the shrinker reported a reduced prefix"
        t_diag "no 'shrink: prefix:' line -- got [${REDUCED}]; the reduction did" \
            "not happen, so every row below it would be measuring nothing"
        awk '/^sim: NOT shrinking/,0' "${LOG}" | sed -e 's/^/# /' | head -8
        t_done
        ;;
esac
t_ok "the shrinker reported a reduced prefix"

t_rc 0 "the prefix reduced to ${REDUCED} of ${STEPS} steps" \
    -- test "${REDUCED}" -lt "${STEPS}"

t_like "$( cat "${LOG}" )" '^shrink: reduced trace \([0-9]+ step\(s\)\):' \
    "and the reduced trace is printed for a person to read"

# The kinds left in the reduction are the ones the failure is about: a node has
# to stop answering and somebody has to promote it.
TRACE=$( sed -n '/^shrink: reduced trace/,$p' "${LOG}" )
t_like "${TRACE}" '(kill|isolate)' \
    "the reduced trace still contains the event that takes a node away"
t_like "${TRACE}" '(promote|double-trigger)' \
    "and the event that promotes it, which is where an unfenced promotion becomes visible"

# ---------------------------------------------------------------------------
# The reduction is a reduction: it fails, and one step less does not
# ---------------------------------------------------------------------------

SKIP=$( awk '/^shrink: removed kinds: /{ sub(/^shrink: removed kinds: /, ""); print }' "${LOG}" )
[ "${SKIP}" = "none" ] && SKIP=""

env SEANCE_SEED="${SEED}" SEANCE_SIM_STEPS="${REDUCED}" \
    SEANCE_SIM_SKIP="${SKIP}" SEANCE_SIM_NO_SHRINK=1 \
    SEANCE_ROOT="${SCRATCH}" REAPER_OUT="${OUTDIR}" \
    sh "${SCRATCH}/tests/cluster/sim/run.sh" > "${OUTDIR}/reduced.log" 2>&1
RRC=$?
t_is "${RRC}" "1" \
    "the reduced trace reproduces the failure on a cluster it has never seen"

if [ "${REDUCED}" -gt 1 ]; then
    env SEANCE_SEED="${SEED}" SEANCE_SIM_STEPS="$(( REDUCED - 1 ))" \
        SEANCE_SIM_SKIP="${SKIP}" SEANCE_SIM_NO_SHRINK=1 \
        SEANCE_ROOT="${SCRATCH}" REAPER_OUT="${OUTDIR}" \
        sh "${SCRATCH}/tests/cluster/sim/run.sh" > "${OUTDIR}/one-less.log" 2>&1
    LRC=$?
    t_is "${LRC}" "0" \
        "and one step less does not: the prefix the shrinker reports is the shortest that fails"
else
    t_ok "the reduction is one step, so there is no shorter prefix to disprove"
fi

t_diag "evidence in ${OUTDIR}"

t_done
