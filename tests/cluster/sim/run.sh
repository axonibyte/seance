#!/bin/sh
# seance tier 7 -- the driver: seed -> event trace -> verdict.
#
#   sh tests/cluster/sim/run.sh
#
# Environment (DESIGN.md §2, §9):
#
#   SEANCE_SEED            the seed. Absent, one is drawn from /dev/urandom and
#                          PRINTED as the first line, because a run whose seed
#                          nobody wrote down is a run nobody can repeat.
#   SEANCE_SIM_STEPS       how many events (default 60).
#   SEANCE_SIM_SKIP        comma-separated event kinds to draw and then SKIP.
#                          The shrinker's second reduction; the draw still
#                          happens so that the stream stays aligned.
#   SEANCE_SIM_N           how many nodes (default 3; 4 for the even-N profile,
#                          because the even-N freeze has to be exercised).
#   SEANCE_SIM_DRY         1: draw and model the trace with NO cluster at all.
#                          The generator, the model's applicability rules and
#                          the trace format are then testable on a workstation,
#                          which is where they are edited.
#   SEANCE_SIM_NO_SHRINK   1: on failure, do not shrink. Set by the shrinker's
#                          own reruns (or they would recurse), and by the
#                          rediscovery battery, where the failure IS the result
#                          and reducing it would cost a cluster rebuild per
#                          bisection step for no information.
#   SEANCE_SIM_STEP_TIMEOUT  seconds any one seance invocation may take
#                          (oracle.subr; the default is 120).
#   SEANCE_SIM_SHRINK_BUDGET  seconds the reduction of a failing trace may
#                          cost (default 1800). Every rerun rebuilds a cluster;
#                          when the estimate does not fit, the unreduced trace
#                          is printed instead and the run still fails.
#
# Output: the seed first, then one line per event, then the invariant verdicts
# of every step. Exit 0 when nothing fired, 1 when something did, 2 when the
# driver itself could not run, 3 when the run was KILLED before it reached a
# verdict (see sim_abort below).
#
# THE TRACE IS WRITTEN AS IT HAPPENS, to $REAPER_OUT/sim/<seed>.trace when
# reaper is around and to the run's own directory otherwise, so that a failing
# run's trace is data even if the process dies.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

SEANCE_ROOT=${SEANCE_ROOT:-$( cd "$( dirname "$( realpath "$0" )" )/../../.." && pwd )}
export SEANCE_ROOT

SIM_DRY=${SEANCE_SIM_DRY:-0}

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/harness.subr
. "${SEANCE_ROOT}/tests/lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=gen.subr
. "${SEANCE_ROOT}/tests/cluster/sim/gen.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=model.subr
. "${SEANCE_ROOT}/tests/cluster/sim/model.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=oracle.subr
. "${SEANCE_ROOT}/tests/cluster/sim/oracle.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=invariants.subr
. "${SEANCE_ROOT}/tests/cluster/sim/invariants.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=shrink.subr
. "${SEANCE_ROOT}/tests/cluster/sim/shrink.subr"

if [ "${SIM_DRY}" != "1" ]; then
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=../lib/cluster.subr
    . "${SEANCE_ROOT}/tests/cluster/lib/cluster.subr"
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=../lib/fence.subr
    . "${SEANCE_ROOT}/tests/cluster/lib/fence.subr"
    # shellcheck source-path=SCRIPTDIR
    # shellcheck source=world.subr
    . "${SEANCE_ROOT}/tests/cluster/sim/world.subr"
fi

SIM_STEPS=${SEANCE_SIM_STEPS:-60}
SIM_SKIP=${SEANCE_SIM_SKIP:-}
SIM_N=${SEANCE_SIM_N:-3}
SIM_NO_SHRINK=${SEANCE_SIM_NO_SHRINK:-0}

# The virtual epoch the trace starts at. A fixed instant rather than the real
# clock: the whole point of SEANCE_NOW is that two runs of one seed see the
# same timestamps, and a start drawn from date(1) would put the wall clock back
# into the snapshot names (DESIGN §2). 2026-01-01T00:00:00Z.
SIM_EPOCH=1767225600

sim_diag()
{
    printf '# sim: %s\n' "$*" >&2
}

sim_die()
{
    printf 'sim: FAIL: %s\n' "$*" >&2
    exit 2
}

case "${SIM_STEPS}" in
    ''|*[!0-9]*) sim_die "SEANCE_SIM_STEPS is not a whole number: [${SIM_STEPS}]" ;;
esac
[ "${SIM_STEPS}" -ge 1 ] || sim_die "SEANCE_SIM_STEPS must be at least 1"

case "${SIM_N}" in
    ''|*[!0-9]*) sim_die "SEANCE_SIM_N is not a whole number: [${SIM_N}]" ;;
esac
[ "${SIM_N}" -ge 2 ] || sim_die "SEANCE_SIM_N must be at least 2"

# --- the seed ---------------------------------------------------------------
#
# From the environment when there is one; otherwise drawn OUTSIDE the seeded
# stream, from /dev/urandom, and announced before anything else happens.
if [ -n "${SEANCE_SEED:-}" ]; then
    SIM_SEED=${SEANCE_SEED}
else
    SIM_SEED=$( od -An -N4 -tu4 < /dev/urandom | tr -d ' \n' )
    [ -n "${SIM_SEED}" ] || sim_die "could not draw a seed from /dev/urandom"
fi

gen_seed "${SIM_SEED}" || sim_die "not a usable seed: [${SIM_SEED}]"
gen_announce

# --- a run that is killed did not find anything ------------------------------
#
# The harness's own signal trap tears the fixture down and exits 1 -- which is
# the status an invariant firing exits with, so a battery cannot tell the two
# apart. On 2026-08-17 that is exactly what happened: an interrupted battery
# left three of the five committed seeds with logs that stop in the middle of a
# step, every node's tick reported by the oracle as 'no verdict: the verb wrote
# nothing to stdout' (jexec entering jails the teardown had already removed),
# and all three seeds were written to seeds-to-promote.txt as having found a
# defect. None of them had found anything, and the next session was spent
# proving it.
#
# So an interrupted run says so, in a verdict line of its own, and leaves by a
# door of its own: exit 3. Teardown is unchanged -- exit runs the harness's
# EXIT trap, which is where the cluster_down that cluster_arm_teardown
# registered lives -- and the run still fails, because 3 is not 0.
# shellcheck disable=SC2329
#   "This function is never invoked": it is, from the three traps immediately
#   below, and shellcheck does not read the inside of a trap string. Narrowed
#   to this one function.
sim_abort()
{
    printf 'sim: ABORTED on %s at step %s, seed %s: killed before a verdict\n' \
        "$1" "${step:-0}" "${SIM_SEED}"
    exit 3
}

trap 'sim_abort HUP' HUP
trap 'sim_abort INT' INT
trap 'sim_abort TERM' TERM

# --- where the evidence goes -------------------------------------------------

SIM_DIR=$( t_tmpdir )
SIM_OUT=""

if [ -n "${REAPER_OUT:-}" ]; then
    SIM_OUT="${REAPER_OUT}/sim/${SIM_SEED}"
    mkdir -p "${SIM_OUT}" || sim_die "cannot create ${SIM_OUT}"
    SIM_TRACE="${REAPER_OUT}/sim/${SIM_SEED}.trace"
else
    SIM_TRACE="${SIM_DIR}/${SIM_SEED}.trace"
fi

: > "${SIM_TRACE}" || sim_die "cannot write the trace at ${SIM_TRACE}"
printf '# seed %s\n' "${SIM_SEED}" >> "${SIM_TRACE}"

# Every invocation's capture directory goes where the trace goes, so a failing
# seed leaves stdout, stderr, rc and elapsed time for a person to read.
if [ -n "${SIM_OUT}" ]; then
    ORACLE_CAPTURE_ROOT="${SIM_OUT}/captures"
else
    ORACLE_CAPTURE_ROOT="${SIM_DIR}/captures"
fi
mkdir -p "${ORACLE_CAPTURE_ROOT}" || sim_die "cannot create the capture root"

# ---------------------------------------------------------------------------
# Choosing an event's arguments
#
# Every draw goes through gen.subr, and every candidate list comes from the
# MODEL (DESIGN §4). Nothing here asks the cluster what it should do next: a
# generator that did would produce a trace that cannot be replayed, because the
# cluster is not the same twice.
# ---------------------------------------------------------------------------

# The shift a skew event applies: past the fleet's tolerance by a minute, in
# either direction, so that a node's own idea of now is outside what seance is
# willing to call agreement (DESIGN §4). In a dry run world.subr is not sourced
# and the fleet's tolerance is the same number written once here.
SIM_SKEW_STEP=$(( ${WORLD_SKEW_TOLERANCE:-120} + 60 ))

# NOTHING THAT DRAWS MAY RUN IN A COMMAND SUBSTITUTION.
#
# gen.subr's stream is a shell variable, and `x=$( gen_below 3 )` advances it in
# a FORKED shell that then exits -- so the parent draws the same value for ever.
# Found by the first dry run of this file, which dealt `tick` and `skew` and
# nothing else for twenty steps and looked plausible while doing it. Every
# drawing function below therefore ASSIGNS its answer to a global and prints
# nothing, and every caller reads the global. gen.subr says the same thing
# about its own callers in its header; this is that rule applied one level up.

SIM_LINE=""      # sim_pick_line's answer
SIM_ARGS=""      # sim_pick's answer

# sim_pick_line <lines>  -- one line of a newline-separated list, seeded.
sim_pick_line()
{
    local _n

    SIM_LINE=""

    _n=$( printf '%s\n' "$1" | awk 'NF > 0 { n++ } END { print n + 0 }' )
    [ "${_n}" -ge 1 ] || return 1

    gen_below "${_n}" > /dev/null || return 1
    SIM_LINE=$( printf '%s\n' "$1" | awk -v want="$(( GEN_VALUE + 1 ))" \
        'NF > 0 { n++; if (n == want) { print; exit } }' )

    [ -n "${SIM_LINE}" ]
}

# sim_pick <kind>  -- draw that kind's arguments into SIM_ARGS.
sim_pick()
{
    local _kind _sign

    _kind=$1
    SIM_ARGS=""

    case "${_kind}" in
        tick)
            return 0
            ;;
        kill|isolate|flap)
            sim_pick_line "$( model_live )" || return 1
            ;;
        heal)
            sim_pick_line "$( model_nodes_in isolated )" || return 1
            ;;
        promote)
            sim_pick_line "$( model_promote_pairs )" || return 1
            ;;
        double-trigger)
            sim_pick_line "$( model_double_pairs )" || return 1
            ;;
        return)
            sim_pick_line "$( model_nodes_in dead )" || return 1
            ;;
        failback)
            sim_pick_line "$( sim_failback_pairs )" || return 1
            ;;
        prune-during-send)
            sim_pick_line "$( model_hosted_pairs )" || return 1
            ;;
        hostile-snap)
            sim_pick_line "$( model_hosted_pairs )" || return 1
            gen_below 2 > /dev/null || return 1
            if [ "${GEN_VALUE}" -eq 0 ]; then
                SIM_LINE="${SIM_LINE} foreign"
            else
                SIM_LINE="${SIM_LINE} badts"
            fi
            ;;
        hand-mount)
            sim_pick_line "$( model_handmount_pairs )" || return 1
            ;;
        skew)
            sim_pick_line "$( model_live )" || return 1
            gen_below 2 > /dev/null || return 1
            if [ "${GEN_VALUE}" -eq 0 ]; then
                _sign=${SIM_SKEW_STEP}
            else
                _sign=$(( 0 - SIM_SKEW_STEP ))
            fi
            SIM_LINE="${SIM_LINE} ${_sign}"
            ;;
        *)
            sim_diag "no such event kind: ${_kind}"
            return 1
            ;;
    esac

    SIM_ARGS=${SIM_LINE}
    return 0
}

# sim_failback_pairs  -- "<guest> <home>" for every guest that could come home.
sim_failback_pairs()
{
    local _g _home _place _live

    _live=$( model_live | tr '\n' ' ' )

    for _g in $( model_keys "${MODEL_GUESTS}" ); do
        _home=$( model_home "${_g}" )
        _place=$( model_placement "${_g}" )
        [ "${_place}" = "${_home}" ] && continue
        model_in "${_home}" "${_live}" || continue
        model_in "${_place}" "${_live}" || continue
        printf '%s %s\n' "${_g}" "${_home}"
    done

    return 0
}

# sim_skipped <kind>  -- rc 0 if SEANCE_SIM_SKIP names this kind.
sim_skipped()
{
    local _k

    for _k in $( printf '%s\n' "${SIM_SKIP}" | tr ',' ' ' ); do
        [ "${_k}" = "$1" ] && return 0
    done

    return 1
}

# ---------------------------------------------------------------------------
# Applying an event to the world
# ---------------------------------------------------------------------------

# sim_apply <kind> <args...>
sim_apply()
{
    local _kind _a1 _a2 _a3 _refused

    _kind=$1
    _a1=${2:-}
    _a2=${3:-}
    _a3=${4:-}

    case "${_kind}" in
        tick)              world_tick ;;
        kill)              world_kill "${_a1}" || return 1 ;;
        isolate)           world_isolate "${_a1}" || return 1 ;;
        heal)              world_heal "${_a1}" || return 1 ;;
        flap)              world_flap "${_a1}" || return 1 ;;
        promote)           world_promote "${_a1}" "${_a2}" ;;
        double-trigger)    world_double_trigger "${_a1}" "${_a2}" "${_a3}" ;;
        return)            world_return "${_a1}" || return 1 ;;
        failback)          world_failback "${_a1}" "${_a2}" ;;
        prune-during-send) world_prune_during_send "${_a1}" "${_a2}" ;;
        hostile-snap)      world_hostile_snap "${_a1}" "${_a2}" "${_a3}" ;;
        skew)              world_skew "${_a1}" "${_a2}" ;;
        hand-mount)
            _refused=$( world_hand_mount "${_a1}" "${_a2}" \
                "$( model_placement "${_a1}" )" )
            if [ "${_refused}" = "refused" ]; then
                model_refuse "${_a1}" "${_a2}"
            else
                model_unrefuse "${_a1}" "${_a2}"
            fi
            ;;
        *)
            sim_diag "cannot apply an unknown event kind: ${_kind}"
            return 1
            ;;
    esac

    return 0
}

# ---------------------------------------------------------------------------
# Building the fleet the seed deals
# ---------------------------------------------------------------------------

# sim_deal  -- the guests, their homes and their types, from the seeded stream.
#
# Four guests: enough for a node to hold more than one and for a promotion to
# have to walk an estate, few enough that a tick costs seconds rather than
# minutes. One of them carries a per-guest heir override (DESIGN §3), which is
# also the D-130 case: CARP wakes the node's heir and that guest's actor is
# somebody else.
SIM_GUESTS="web01 db01 arc01 mail01"

sim_deal()
{
    local _g _home _type _i _nodes

    _nodes=$( model_keys "${MODEL_NODES}" | tr '\n' ' ' )
    _i=0

    for _g in ${SIM_GUESTS}; do
        # shellcheck disable=SC2086
        #   Deliberate word splitting: the roster becomes one argument per node.
        gen_choose ${_nodes} > /dev/null || return 1
        _home=${GEN_CHOICE}

        gen_below 4 > /dev/null || return 1
        if [ "${GEN_VALUE}" -eq 0 ]; then
            _type=bhyve
        else
            _type=jail
        fi

        SIM_HOMES="${SIM_HOMES} ${_g}=${_home}"
        SIM_TYPES="${SIM_TYPES} ${_g}=${_type}"
        _i=$(( _i + 1 ))
    done

    # The override is dealt too, so that which guest carries it is a function of
    # the seed rather than of the alphabet.
    # shellcheck disable=SC2086
    #   Deliberate word splitting over the guest list.
    gen_choose ${SIM_GUESTS} > /dev/null || return 1
    SIM_OVERRIDE=${GEN_CHOICE}

    return 0
}

SIM_HOMES=""
SIM_TYPES=""
SIM_OVERRIDE=""

# sim_home <guest> / sim_type <guest>
sim_home()
{
    model_get "${SIM_HOMES}" "$1"
}

sim_type()
{
    model_get "${SIM_TYPES}" "$1"
}

# ---------------------------------------------------------------------------
# The run
# ---------------------------------------------------------------------------

# The node names are the substrate's own (cluster.subr's CLUSTER_NAMES), first
# N of them. Spelled here as well because a dry run has no substrate to ask.
SIM_ROSTER=$( awk -v n="${SIM_N}" 'BEGIN {
    split("alpha bravo charlie delta echo foxtrot", a, " ")
    for (i = 1; i <= n; i++) printf "%s ", a[i]
}' )

# shellcheck disable=SC2086
#   Deliberate word splitting: the roster becomes one argument per node.
model_init "${SIM_DIR}/model" "${WORLD_CADENCE:-60}" "${SIM_EPOCH}" ${SIM_ROSTER} ||
    sim_die "the model could not be initialised"

sim_deal || sim_die "the seeded stream could not deal a fleet"

# The succession every node and every guest has, told to the model rather than
# derived twice: the world writes it into the configuration file, and both must
# be the same arrangement or the model is checking a fleet that does not exist.
SIM_NODES=$( model_keys "${MODEL_NODES}" | tr '\n' ' ' )

sim_nth()
{
    printf '%s\n' "${SIM_NODES}" | awk -v i="$1" -v n="${SIM_N}" \
        '{ print $(( (i % n) + 1 )) }'
}

sim_index()
{
    printf '%s\n' "${SIM_NODES}" | awk -v w="$1" \
        '{ for (i = 1; i <= NF; i++) if ($i == w) { print i - 1; exit } }'
}

sim_heir()
{
    sim_nth "$(( $( sim_index "$1" ) + 1 ))"
}

sim_heir2()
{
    sim_nth "$(( $( sim_index "$1" ) + 2 ))"
}

for n in ${SIM_NODES}; do
    model_set_node_heirs "${n}" "$( sim_heir "${n}" )" "$( sim_heir2 "${n}" )"
done

for g in ${SIM_GUESTS}; do
    home=$( sim_home "${g}" )
    if [ "${g}" = "${SIM_OVERRIDE}" ]; then
        # The override reverses the home node's own order, which is what makes
        # the guest's actor a node no CARP transition wakes (D-129/D-130).
        model_add_guest "${g}" "${home}" "$( sim_heir2 "${home}" )" \
            "$( sim_heir "${home}" )"
    else
        model_add_guest "${g}" "${home}" "$( sim_heir "${home}" )" \
            "$( sim_heir2 "${home}" )"
    fi
done

printf '# fleet %s nodes, guests:' "${SIM_N}"
for g in ${SIM_GUESTS}; do
    printf ' %s@%s' "${g}" "$( sim_home "${g}" )"
done
printf ' (override: %s)\n' "${SIM_OVERRIDE}"

# --- the dry run: no cluster, no seance, no invariants ------------------------
#
# What it proves is what it can: that the generator is deterministic, that the
# model's applicability rules never offer an event with no candidates, and that
# the trace has the shape the shrinker parses. All three are edited on a
# workstation and would otherwise only be exercised inside a reaper session.
if [ "${SIM_DRY}" = "1" ]; then
    step=1
    while [ "${step}" -le "${SIM_STEPS}" ]; do
        spec=$( model_applicable )
        [ -n "${spec}" ] || sim_die "step ${step}: no event kind is applicable"

        gen_pick_weighted "${spec}" > /dev/null || sim_die "the generator refused"
        kind=${GEN_PICK}
        sim_pick "${kind}" || sim_die "step ${step}: no ${kind} to pick"
        args=${SIM_ARGS}

        printf '%s %s %s\n' "${step}" "${kind}" "${args}" >> "${SIM_TRACE}"
        printf '%s %s %s\n' "${step}" "${kind}" "${args}"

        if ! sim_skipped "${kind}"; then
            # shellcheck disable=SC2086
            #   Deliberate word splitting: the arguments are a word list.
            model_apply "${kind}" ${args} || sim_die "the model refused ${kind}"
            model_age_skew

        fi

        step=$(( step + 1 ))
    done

    printf 'sim: DRY %s step(s), seed %s\n' "${SIM_STEPS}" "${SIM_SEED}"
    exit 0
fi

# --- the world ---------------------------------------------------------------

if [ "$( id -u )" -ne 0 ]; then
    sim_die "tier 7 builds jails and ZFS datasets; it needs root"
fi

world_up "${SIM_N}" "${SIM_DIR}/world" || sim_die "the world could not be built"
t_at_exit 'fence_uninstall'

# The model and the world derive the ring succession separately -- the model so
# that it can compute applicability with no cluster, the world so that it can
# write the configuration file. They agree only while the two rosters are the
# same list in the same order, and a silent disagreement would have the model
# checking a fleet that does not exist. So it is not assumed.
if [ "${WORLD_NODES}" != "$( printf '%s' "${SIM_ROSTER}" | sed -e 's/ *$//' )" ]; then
    sim_die "the cluster's roster [${WORLD_NODES}] is not the model's [${SIM_ROSTER}]"
fi

WORLD_OVERRIDE=${SIM_OVERRIDE}
world_set_now "${SIM_EPOCH}"

for g in ${SIM_GUESTS}; do
    world_add_guest "${g}" "$( sim_home "${g}" )" "$( sim_type "${g}" )" ||
        sim_die "guest ${g} could not be created"
done

world_configure || sim_die "the world could not be configured"

# Two ticks before the first event, so that every guest has a replica on both
# of its heirs: a trace whose first event is a promotion of a node nobody holds
# anything for would test the refusal and nothing else.
world_tick > /dev/null 2>&1 || true
world_tick > /dev/null 2>&1 || true
model_apply tick
model_apply tick
model_age_skew

SIM_PREV=""
SIM_CUR="${SIM_DIR}/obs.a"
SIM_MODEL="${SIM_DIR}/model-state"

sim_rc=0
step=1
SIM_T0=$( date +%s )

while [ "${step}" -le "${SIM_STEPS}" ]; do
    spec=$( model_applicable )
    [ -n "${spec}" ] || sim_die "step ${step}: no event kind is applicable"

    gen_pick_weighted "${spec}" > /dev/null || sim_die "the generator refused"
    kind=${GEN_PICK}
    sim_pick "${kind}" || sim_die "step ${step}: no ${kind} to pick"
    args=${SIM_ARGS}

    printf '%s %s %s\n' "${step}" "${kind}" "${args}" >> "${SIM_TRACE}"
    printf 'step %s: %s %s\n' "${step}" "${kind}" "${args}"

    if sim_skipped "${kind}"; then
        printf 'step %s: skipped (SEANCE_SIM_SKIP)\n' "${step}"
        step=$(( step + 1 ))
        continue
    fi

    # Every invocation this step makes, for invariant 5.
    rm -rf "${SIM_CUR}"
    mkdir -p "${SIM_CUR}" || sim_die "cannot create ${SIM_CUR}"
    ORACLE_INVOCATIONS_FILE="${SIM_CUR}/invocations"
    export ORACLE_INVOCATIONS_FILE
    : > "${ORACLE_INVOCATIONS_FILE}"

    # shellcheck disable=SC2086
    #   Deliberate word splitting: the arguments are a word list.
    sim_apply "${kind}" ${args} || sim_die "step ${step}: the world could not apply ${kind}"

    # shellcheck disable=SC2086
    model_apply "${kind}" ${args} || sim_die "step ${step}: the model refused ${kind}"

    # The clock ages once, in the model, and the world is TOLD -- rather than
    # each of them keeping its own idea of how long a skew lasts. Done after
    # the event and before the next one, so that within a step the world's
    # SEANCE_NOW and the model's prediction are the same instant (D-140).
    model_age_skew
    world_skew "${MODEL_SKEW_NODE}" "${MODEL_SKEW_OFFSET}"

    # What the world says the nodes are now, which is not always what the event
    # asked for: a promotion's rung 4 fences, and a fenced node is stopped.
    for n in ${WORLD_NODES}; do
        model_set_node_state "${n}" "$( world_node_state "${n}" )"
    done

    world_observe "${SIM_CUR}" || sim_die "step ${step}: the world could not be observed"
    model_sync_placement "${SIM_CUR}"
    model_write "${SIM_MODEL}" || sim_die "step ${step}: the model could not be written"

    if ! inv_check_all "${SIM_MODEL}" "${SIM_CUR}" "${SIM_PREV}"; then
        printf 'sim: FAILED at step %s (%s %s), seed %s\n' \
            "${step}" "${kind}" "${args}" "${SIM_SEED}"
        sim_rc=1
        break
    fi

    # Two observations are kept, because invariants 3 and 4 are transition
    # invariants; the third is what the second one was.
    SIM_PREV=${SIM_CUR}
    if [ "${SIM_CUR}" = "${SIM_DIR}/obs.a" ]; then
        SIM_CUR="${SIM_DIR}/obs.b"
    else
        SIM_CUR="${SIM_DIR}/obs.a"
    fi

    step=$(( step + 1 ))
done

# The invariants are checked after every event, and the last event's check IS
# the check "at the end" DESIGN §6 asks for -- there is no state between the
# last event and the end of the run for a further check to be about.

if [ "${sim_rc}" -eq 0 ]; then
    printf 'sim: PASS %s step(s), seed %s\n' "${SIM_STEPS}" "${SIM_SEED}"
    exit 0
fi

# --- the failure ------------------------------------------------------------

if [ -n "${SIM_OUT}" ]; then
    cp -R "${SIM_MODEL}" "${SIM_OUT}/model" 2>/dev/null || true
    [ -n "${SIM_PREV}" ] && cp -R "${SIM_PREV}" "${SIM_OUT}/observed-prev" 2>/dev/null
    cp -R "${SIM_CUR}" "${SIM_OUT}/observed" 2>/dev/null || true
    printf 'sim: evidence in %s\n' "${SIM_OUT}"
fi

if [ "${SIM_NO_SHRINK}" = "1" ]; then
    printf 'sim: not shrinking (SEANCE_SIM_NO_SHRINK=1); the trace is at %s\n' \
        "${SIM_TRACE}"
    exit 1
fi

# THE CLUSTER GOES FIRST, and this is not tidiness. Every rerun the shrinker
# makes builds its own three-node cluster, and cluster_up refuses to build one
# while another is up -- so a shrinker that started with this run's cluster
# still standing would watch every rerun fail for that reason, conclude that
# one step reproduces the failure, and print a confident one-line trace that
# means nothing. The teardown is idempotent; the harness will call it again at
# exit.
cluster_down || world_diag "the cluster did not tear down cleanly before shrinking"
fence_uninstall

# shrink_rerun <steps> <skip-kinds>
#
# One rerun of THIS seed against a freshly built cluster, which is what makes a
# non-reproduction a weak signal -- shrink_run says so in its own output. The
# rerun does not shrink (or this would recurse) and its own output is kept out
# of the way; its exit status is the whole answer.
shrink_rerun()
{
    # REAPER_OUT is cleared deliberately: a rerun of this seed would otherwise
    # write its trace to the same $REAPER_OUT/sim/<seed>.trace the shrinker is
    # reading, truncate it on its first line, and reduce a file that is no
    # longer there. The rerun keeps its evidence in its own temporary directory;
    # the failing run's evidence has already been copied out above.
    env SEANCE_SEED="${SIM_SEED}" \
        SEANCE_SIM_STEPS="$1" \
        SEANCE_SIM_SKIP="$2" \
        SEANCE_SIM_N="${SIM_N}" \
        SEANCE_SIM_NO_SHRINK=1 \
        SEANCE_ROOT="${SEANCE_ROOT}" \
        REAPER_OUT= \
        sh "${SEANCE_ROOT}/tests/cluster/sim/run.sh" \
        > "${SIM_DIR}/rerun.log" 2>&1
}

# IS THERE TIME TO SHRINK? Every rerun rebuilds a three-node cluster and
# replays the trace, and the reduction is a binary search over the prefix
# (about log2(steps) reruns) plus one per event kind still present -- call it
# fifteen, each costing at most what this run cost. A shrink nobody budgeted
# for can eat a session that was meant to run the whole battery, so the
# estimate is made out loud and compared against a budget, and when it does not
# fit the UNREDUCED trace is printed instead. The verdict is unchanged either
# way: the run failed, and it says so.
SIM_ELAPSED=$(( $( date +%s ) - SIM_T0 ))
SIM_SHRINK_BUDGET=${SEANCE_SIM_SHRINK_BUDGET:-1800}
SIM_SHRINK_COST=$(( SIM_ELAPSED * 15 ))

if [ "${SIM_SHRINK_COST}" -gt "${SIM_SHRINK_BUDGET}" ]; then
    printf 'sim: NOT shrinking: this run took %ss, so a reduction is about %ss,\n' \
        "${SIM_ELAPSED}" "${SIM_SHRINK_COST}"
    printf 'sim: past the SEANCE_SIM_SHRINK_BUDGET of %ss. Raise it and rerun\n' \
        "${SIM_SHRINK_BUDGET}"
    printf 'sim: with SEANCE_SEED=%s to reduce this trace. It is, in full:\n' \
        "${SIM_SEED}"
    awk '/^[ \t]*#/ { next } NF > 0 { print "  " $0 }' "${SIM_TRACE}"
    exit 1
fi

printf 'sim: shrinking seed %s (%s steps, about %ss of reruns)\n' \
    "${SIM_SEED}" "${SIM_STEPS}" "${SIM_SHRINK_COST}"
shrink_run "${SIM_TRACE}"

exit 1
