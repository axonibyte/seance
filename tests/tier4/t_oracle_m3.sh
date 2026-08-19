#!/bin/sh
# Tier 4 -- the tier-7 invariants, fed a REAL tier-7 state.
#
# Three files ask the checker three different questions:
#
#   t_sim_oracle_selftest.sh   hand-built states: can every invariant fire?
#   t_oracle_m2.sh             a state built by running rung 6 for real: does
#                              the file-format contract describe the records
#                              seance actually writes?
#   this one                   a state a TIER-7 RUN observed, captured whole
#                              from the guest: does the checker still see what
#                              it is for when the state is one the world driver
#                              produced, in a cluster that had really promoted
#                              a guest?
#
# The capture is `tests/tier4/sim-capture/`: seed 2950315648 at 8 steps, in the
# reaper guest on 2026-08-19, kept because a PASSING run now leaves its last
# state behind (M3/U12). Its shape is the one that matters -- alpha is dead,
# bravo holds mail01 away from home with `fence:jail` in the succession log,
# every other copy is hidden, and the model says which nodes are alive. That is
# the M3 state: placement, carp-driven promotion, records.
#
# WHY A CAPTURED STATE AND NOT A HAND-BUILT ONE. Silence from a checker has two
# possible meanings -- "nothing is wrong" and "I could not read this" -- and
# only a state produced by the real driver can tell them apart. Each corruption
# below is applied to a copy of that state, one at a time, and the invariant it
# belongs to must fire; the checker is also asked once about the state
# untouched, where it must say nothing at all.
#
# THE ONE THAT IS NOT A CORRUPTION is D-150's narrowing on a real state: the
# dead node's stale claim. A node the fence stopped goes on claiming its estate
# from a disk nobody is running, and counting that as a second claimant fires
# invariant 1 on the exact sequence seance exists to make safe.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/sim/oracle.subr
. "${T_ROOT}/tests/cluster/sim/oracle.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/sim/invariants.subr
. "${T_ROOT}/tests/cluster/sim/invariants.subr"

CAPTURE="${T_ROOT}/tests/tier4/sim-capture"
TAB=$( printf '\t.' )
TAB=${TAB%.}

# world  -- a private copy of the capture, with the invocation list pointed at
# this copy's own capture directories. The paths in it are the guest's, and a
# state whose invocations cannot be read is a state invariant 5 fires on for a
# reason that has nothing to do with what is being tested.
world()
{
    local _d _f _n

    _d=$( t_tmpdir )/world
    mkdir -p "${_d}"
    cp -R "${CAPTURE}/observed" "${CAPTURE}/observed-prev" "${CAPTURE}/model" \
        "${CAPTURE}/captures" "${_d}/"

    for _f in "${_d}/observed/invocations" "${_d}/observed-prev/invocations"; do
        [ -r "${_f}" ] || continue
        awk -v root="${_d}/captures" '
            NF > 0 { n = split($0, p, "/"); print root "/" p[n] }
        ' "${_f}" > "${_f}.new"
        mv "${_f}.new" "${_f}"
    done

    printf '%s\n' "${_d}"
}

# check <world-dir>  -- every invariant against that world, output captured.
CHECK_OUT=""
CHECK_RC=0
check()
{
    CHECK_OUT=$( inv_check_all "$1/model" "$1/observed" "$1/observed-prev" 2>&1 )
    CHECK_RC=$?
}

# fires <n> <name>  -- invariant <n> must have fired, and the run must fail.
fires()
{
    if [ "${CHECK_RC}" -eq 0 ]; then
        t_not_ok "$2"
        t_diag "the checker passed a state it should have complained about"
        return 0
    fi
    t_like "${CHECK_OUT}" "invariant $1 FIRED" "$2"
}

t_plan 18

# ---------------------------------------------------------------------------
# The capture is what it claims to be
# ---------------------------------------------------------------------------

t_rc 0 "the captured state is in the tree" -- test -r "${CAPTURE}/observed/placement"
t_is "$( cat "${CAPTURE}/observed/placement" )" "bravo${TAB}mail01${TAB}active" \
    "and it is a post-promotion state: bravo claims mail01, which is alpha's"
t_like "$( cat "${CAPTURE}/observed/records" )" "fence:jail\$" \
    "with a succession record whose evidence is the fence, not a force"
t_like "$( cat "${CAPTURE}/model/nodes" )" "^alpha${TAB}dead\$" \
    "and the model knows alpha is dead, which is what makes its stale claim a stale claim"

# ---------------------------------------------------------------------------
# Untouched: the checker says nothing
# ---------------------------------------------------------------------------

W=$( world )
check "${W}"
t_is "${CHECK_RC}" "0" \
    "no invariant fires on the state as the tier-7 run observed it"
t_unlike "${CHECK_OUT}" "FIRED" "and nothing in its output says FIRED"
t_like "${CHECK_OUT}" "invariant 5 ok" \
    "-- and invariant 5 read the invocations, so the silence is a reading and not a shrug"

# THE ONE THAT MUST STAY QUIET, and it is D-150's own shape on a real state:
# alpha promoted charlie's arc01 while it was alive, an heir then fenced alpha
# and promoted arc01 in its turn, and alpha's placement file still says
# 'active' -- from a disk nobody is running, which nobody can rewrite. Both
# claims carry their own succession record, because that is what a real one
# does; what is being asked is only whether the corpse counts as a claimant.
staleclaim()
{
    local _d _f

    _d=$1
    for _f in "${_d}/observed" "${_d}/observed-prev"; do
        printf 'alpha%sarc01%sactive\n' "${TAB}" "${TAB}" >> "${_f}/placement"
        printf 'bravo%sarc01%sactive\n' "${TAB}" "${TAB}" >> "${_f}/placement"
        printf 'alpha%sarc01%scharlie%salpha%s20260101T000200Z%sfence:jail\n' \
            "${TAB}" "${TAB}" "${TAB}" "${TAB}" "${TAB}" >> "${_f}/records"
        printf 'bravo%sarc01%scharlie%sbravo%s20260101T000300Z%sfence:jail\n' \
            "${TAB}" "${TAB}" "${TAB}" "${TAB}" "${TAB}" >> "${_f}/records"
    done
}

W=$( world )
staleclaim "${W}"
check "${W}"
t_is "${CHECK_RC}" "0" \
    "a DEAD node's stale claim beside a LIVE node's is not two claimants (D-150)"
t_unlike "${CHECK_OUT}" "invariant 1 FIRED" \
    "-- invariant 1 in particular stays quiet, which is the narrowing being exercised"

# ---------------------------------------------------------------------------
# One corruption at a time, and the matching invariant must fire
# ---------------------------------------------------------------------------

# 1A -- the guest is running in two places. The process fact, which is the one
# clause D-150 did not narrow.
W=$( world )
printf 'mail01%scharlie%s1\n' "${TAB}" "${TAB}" >> "${W}/observed/running"
check "${W}"
fires 1 "a guest running on two nodes fires invariant 1"

# 1B -- two LIVE nodes claim it.
W=$( world )
printf 'charlie%smail01%sactive\n' "${TAB}" "${TAB}" >> "${W}/observed/placement"
check "${W}"
fires 1 "two LIVE nodes claiming one guest fires invariant 1"

# 2 -- the promotion's evidence is gone. This is the August catalogue's own
# question: a guest that moved, and nothing saying anything confirmed it.
W=$( world )
: > "${W}/observed/records"
check "${W}"
fires 2 "a guest placed away from home with no succession record fires invariant 2"

# 2 -- the record is there and its evidence is not one seance writes.
W=$( world )
sed -e 's/fence:jail/hopeful/' "${W}/observed/records" > "${W}/observed/records.new"
mv "${W}/observed/records.new" "${W}/observed/records"
check "${W}"
fires 2 "a record whose evidence is not a fence or a force fires invariant 2"

# 3 -- a replica regresses. The newest snapshot of a guest on a node goes
# backwards between two observed states, which no correct replication can do.
W=$( world )
grep -Ev "^charlie${TAB}arc01${TAB}seance-charlie-20260101T00(04|05)00Z\$" \
    "${W}/observed/snapshots" > "${W}/observed/snapshots.new"
mv "${W}/observed/snapshots.new" "${W}/observed/snapshots"
check "${W}"
fires 3 "a replica whose newest snapshot went backwards fires invariant 3"

# 4 -- a data-bearing dataset is gone from one observation to the next.
W=$( world )
grep -v "^charlie${TAB}tank/state/seance/charlie/arc01/data\$" \
    "${W}/observed/datasets" > "${W}/observed/datasets.new"
mv "${W}/observed/datasets.new" "${W}/observed/datasets"
check "${W}"
fires 4 "a dataset that existed and does not any more fires invariant 4"

# 4a -- a replica that could mount itself. The shadow-mount law, on a node that
# does not claim the guest.
W=$( world )
sed -e "s|^charlie${TAB}web01${TAB}mountpoint${TAB}none\$|charlie${TAB}web01${TAB}mountpoint${TAB}/seance/web01|" \
    "${W}/observed/props" > "${W}/observed/props.new"
mv "${W}/observed/props.new" "${W}/observed/props"
check "${W}"
fires 4a "a replica carrying a live mountpoint on a node that does not claim it fires invariant 4a"

# 5 -- the cheap oracle on every invocation: an exit status outside seance's
# three is a verb that did not decide anything.
W=$( world )
for d in "${W}"/captures/*; do
    printf '137\n' > "${d}/rc"
done
check "${W}"
fires 5 "a seance invocation that exited outside 0/1/2 fires invariant 5"

# 5 -- and the last stdout line is a verdict line, or it is not a verdict.
W=$( world )
for d in "${W}"/captures/*; do
    printf '   half a sentence\n' >> "${d}/stdout"
done
check "${W}"
fires 5 "a verb whose last stdout line is not a verdict fires invariant 5"

t_done
