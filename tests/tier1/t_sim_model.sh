#!/bin/sh
# Tier 1 -- the tier-7 shadow model's own unit test.
#
# The model decides two things and this file is about both:
#
#   WHAT MAY HAPPEN NEXT. The generator draws only from applicable events
#   (DESIGN §4), and every rule that says what is applicable lives in
#   model.subr. A rule that is too permissive costs a reaper session -- the
#   driver picks an event whose candidate list is empty and the run dies in the
#   fixture rather than in seance. A rule that is too strict is worse: the
#   event kind quietly stops being exercised and the tier reports green for a
#   nemesis that has been switched off.
#
#   WHAT MUST BE TRUE. The model's lineage is a LOWER BOUND that invariant 3
#   compares against the world (model <= observed), so what is asserted here is
#   that it only ever claims a snapshot the world was told to take.
#
# It costs nothing and needs no cluster, which is the whole point: these rules
# are edited on a workstation.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/sim/model.subr
. "${T_ROOT}/tests/cluster/sim/model.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/sim/invariants.subr
. "${T_ROOT}/tests/cluster/sim/invariants.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/policy.subr
. "${T_ROOT}/lib/policy.subr"

DIR=$( t_tmpdir )
EPOCH=1767225600        # 2026-01-01T00:00:00Z

t_plan 39

# fresh  -- a three-node ring with two guests, everything alive and at home.
fresh()
{
    rm -rf "${DIR}/m"
    model_init "${DIR}/m" 60 "${EPOCH}" alpha bravo charlie || return 1

    model_set_node_heirs alpha bravo charlie
    model_set_node_heirs bravo charlie alpha
    model_set_node_heirs charlie alpha bravo

    model_add_guest web01 alpha bravo charlie
    model_add_guest db01 bravo charlie alpha

    return 0
}

# can <kind>  -- "yes" or "no", so that a failing assertion says which.
can()
{
    if model_can "$1"; then
        printf 'yes\n'
    else
        printf 'no\n'
    fi
}

# ---------------------------------------------------------------------------
# The state the checker reads
# ---------------------------------------------------------------------------

fresh || t_diag "the fixture could not be built"
model_write "${DIR}/state" || t_diag "model_write failed"

t_is "$( inv_nodes "${DIR}/state" | tr '\n' ' ' )" "alpha bravo charlie " \
    "the model writes a node roster invariants.subr can read"
t_is "$( inv_guests "${DIR}/state" | tr '\n' ' ' )" "web01 db01 " \
    "and a guest roster"
t_is "$( inv_home "${DIR}/state" web01 )" "alpha" \
    "and each guest's home, which is what invariant 2 measures a move against"
t_rc 0 "the optional refused file is written even when it is empty" \
    -- test -f "${DIR}/state/refused"

# ---------------------------------------------------------------------------
# Applicability: every rule, and the state that flips it
# ---------------------------------------------------------------------------

t_is "$( can heal )" "no" "nothing is isolated, so there is nothing to heal"
t_is "$( can return )" "no" "nothing is dead, so nothing can return"
t_is "$( can promote )" "no" "nothing is dead or isolated, so nobody succeeds anybody"
t_is "$( can failback )" "no" "every guest is at home, so nothing can come home"
t_is "$( can tick )" "yes" "a tick is always applicable while a node is running"
t_is "$( can kill )" "yes" "a three-node fleet may lose one"

model_apply isolate charlie
t_is "$( can heal )" "yes" "an isolated node can be healed"
t_is "$( can promote )" "yes" "and can be succeeded: its heir alpha is reachable"
t_is "$( model_promote_pairs | tr '\n' ' ' )" \
    "charlie alpha alpha charlie bravo charlie " \
    "an isolation produces BOTH kinds of pair: the heir CARP wakes for the isolated node, and the isolated node trying to succeed each peer it hears nothing from"

model_apply heal charlie
model_apply kill bravo
t_is "$( can return )" "yes" "a dead node can return"
t_is "$( model_promote_pairs | tr '\n' ' ' )" "bravo charlie " \
    "and be succeeded by ITS heir, not by whoever is nearest"

# Two live heirs are what a double trigger needs; with bravo dead, its heirs
# charlie and alpha are both up, so this is exactly that case.
t_is "$( can double-trigger )" "yes" "both of a dead node's heirs are live: a double trigger is possible"

model_apply kill charlie
t_is "$( can kill )" "no" \
    "the last reachable node is never killed: a fleet with nothing alive produces no more events worth checking"
t_is "$( can isolate )" "no" "and it is not isolated either, for the same reason"
t_is "$( can double-trigger )" "no" "with only one node left there are not two heirs to trigger"

# ---------------------------------------------------------------------------
# Placement is read back, not guessed -- and failback follows it
# ---------------------------------------------------------------------------

fresh || t_diag "the fixture could not be rebuilt"
mkdir -p "${DIR}/obs"
: > "${DIR}/obs/placement"
printf 'bravo\tweb01\tactive\n' >> "${DIR}/obs/placement"
model_sync_placement "${DIR}/obs"

t_is "$( model_placement web01 )" "bravo" \
    "a placement record moves the model's idea of where a guest is"
t_is "$( model_home web01 )" "alpha" \
    "and does not move its home: a promotion changes where a guest runs, never where it is from"
t_is "$( can failback )" "yes" "a guest away from home, with both ends live, can come home"

model_apply kill alpha
t_is "$( can failback )" "no" "but not while its home is dead"

fresh || t_diag "the fixture could not be rebuilt"
printf 'bravo\tweb01\theld\n' > "${DIR}/obs/placement"
model_sync_placement "${DIR}/obs"
t_is "$( model_placement web01 )" "alpha" \
    "a HELD claim is not a claim to run: the guest is still placed at home"
t_rc 0 "and the hold is remembered, because a held guest is not replicated (D-94)" \
    -- model_held_anywhere web01

# ---------------------------------------------------------------------------
# The one genuine prediction: a local snapshot, and nothing else
# ---------------------------------------------------------------------------

fresh || t_diag "the fixture could not be rebuilt"

model_apply tick
t_is "$( awk -F '\t' '$1 == "web01" && $2 == "alpha" { print $3 }' "${DIR}/m/lineage.db" )" \
    "$( model_ts $(( EPOCH + 60 )) )" \
    "a tick predicts the snapshot the hosting node takes locally"
t_is "$( awk -F '\t' '$1 == "web01" && $2 == "bravo" { print $3 }' "${DIR}/m/lineage.db" )" \
    "" \
    "and predicts NOTHING about the replica: a send crosses a network the nemesis is cutting"

# The model's converter and seance's own are independent implementations, and
# invariant 3 compares one against the other every time it reads a snapshot
# name. They have to agree.
t_is "$( model_ts $(( EPOCH + 60 )) )" "$( pol_epoch_to_ts $(( EPOCH + 60 )) )" \
    "the model's timestamp converter agrees with the product's"

# A dead node hosts nothing, so a tick claims nothing for it.
model_apply kill alpha
model_apply tick
t_is "$( awk -F '\t' '$1 == "web01" && $2 == "alpha" { print $3 }' "${DIR}/m/lineage.db" )" \
    "$( model_ts $(( EPOCH + 60 )) )" \
    "a tick claims nothing for a node that is not running"

# An ISOLATED node is still running, and its own disk does not know it has been
# cut off. Conflating "unreachable" with "stopped" is exactly the mistake the
# quorum rule exists to stop a NODE making, and the model must not make it.
fresh || t_diag "the fixture could not be rebuilt"
model_apply isolate alpha
model_apply tick
t_is "$( awk -F '\t' '$1 == "web01" && $2 == "alpha" { print $3 }' "${DIR}/m/lineage.db" )" \
    "$( model_ts $(( EPOCH + 60 )) )" \
    "an isolated node still snapshots its own guests"

# A held guest is not replicated (D-94), so nothing is predicted for it.
fresh || t_diag "the fixture could not be rebuilt"
printf 'bravo\tweb01\theld\n' > "${DIR}/obs/placement"
model_sync_placement "${DIR}/obs"
model_apply tick
t_is "$( awk -F '\t' '$1 == "web01" { print $3 }' "${DIR}/m/lineage.db" )" "" \
    "a guest held anywhere is not predicted at all: repl skips it"

# Backwards is not a prediction. A node whose clock has been skewed into the
# past takes a snapshot with an earlier name, and the NEWEST timestamp present
# does not go down because of it -- nothing has been destroyed.
fresh || t_diag "the fixture could not be rebuilt"
model_apply tick
model_apply skew alpha -180
model_age_skew
model_apply tick
model_age_skew
t_is "$( awk -F '\t' '$1 == "web01" && $2 == "alpha" { print $3 }' "${DIR}/m/lineage.db" )" \
    "$( model_ts $(( EPOCH + 60 )) )" \
    "a backwards skew never lowers the model's lower bound: the earlier snapshot the skewed node takes does not destroy the later one it already had"

# And the skew is put back after three events, whatever they were (DESIGN §4).
# The ageing is a step-END call, so that within a step the world's SEANCE_NOW
# and the model's prediction are the same instant -- the two of them disagreeing
# about the name of a snapshot is what the first real run fired on (D-140).
t_is "$( model_now alpha )" "$(( EPOCH + 120 - 180 ))" \
    "a skewed node's clock is shifted while the skew stands"
model_apply tick
t_is "$( model_now alpha )" "$(( EPOCH + 180 - 180 ))" \
    "and on the third event, which is the last one it covers"
model_age_skew
model_apply tick
t_is "$( model_now alpha )" "$(( EPOCH + 240 ))" \
    "and is back afterwards"

# ---------------------------------------------------------------------------
# The rule that makes the rest of them load-bearing
#
# Every kind model_applicable offers must have something to pick. This is the
# assertion that catches a rule that is right about the state and wrong about
# the list -- the failure that costs a session rather than a second.
# ---------------------------------------------------------------------------

candidates()
{
    case "$1" in
        tick|skew)         printf 'always\n' ;;
        kill|isolate|flap) model_live ;;
        heal)              model_nodes_in isolated ;;
        return)            model_nodes_in dead ;;
        promote)           model_promote_pairs ;;
        double-trigger)    model_double_pairs ;;
        prune-during-send|hostile-snap) model_hosted_pairs ;;
        hand-mount)        model_handmount_pairs ;;
        failback)          model_failback_pairs ;;
    esac
}

# The driver's own failback list, spelled here so that this file asserts the
# same question the driver asks. (run.sh's sim_failback_pairs is the same rule;
# it lives there because it is the only pair list the driver needs that the
# checker does not.)
model_failback_pairs()
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
}

check_spec()
{
    local _e _kind _empty

    _empty=""

    for _e in $( model_applicable ); do
        _kind=${_e%%:*}
        [ -n "$( candidates "${_kind}" )" ] || _empty="${_empty} ${_kind}"
    done

    printf '%s\n' "${_empty# }"
}

fresh || t_diag "the fixture could not be rebuilt"
t_is "$( check_spec )" "" "every applicable kind has a candidate: the healthy fleet"

model_apply isolate charlie
model_apply tick
t_is "$( check_spec )" "" "and with a node isolated"

model_apply kill bravo
model_apply tick
model_apply tick
model_apply tick
t_is "$( check_spec )" "" "and with one dead, one isolated and three ticks behind it"

printf 'alpha\tdb01\tactive\n' > "${DIR}/obs/placement"
model_sync_placement "${DIR}/obs"
t_is "$( check_spec )" "" "and with a guest promoted away from its home"

t_done
