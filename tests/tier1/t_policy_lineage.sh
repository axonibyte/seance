#!/bin/sh
# Tier 1 -- the lineage/staleness rungs of the promotion ladder.
#
# This is the M1 subset of design §7 rung 5 (handoff §4): before anything is
# mounted or registered, the promoting node asks whether there is a replica at
# all and whether it is recent enough to be worth promoting.
#
# The one rule this file exists to hold down is that --force cannot fix
# "abort". Staleness is a judgement about how much data a promotion would lose
# and an operator is entitled to accept that loss; an absent replica is not a
# judgement, it is a fact about the disk, and a --force that promoted anyway
# would be promoting nothing. A future change that made abort forceable would
# have to break this file to do it.
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

# Noon on the sixteenth. staleness_max 2700 (three default cadences) puts the
# staleness boundary at 11:15:00Z; skew_tolerance 120 puts the skew boundary
# at 12:02:00Z.
NOW=$( pol_ts_to_epoch 20260816T120000Z )

t_plan 48

# replica ts | force | verdict | rc      (staleness_max 2700, skew 120)

while IFS='|' read -r ts force want rc; do
    case "${ts}" in
        '#'*) continue ;;
    esac
    [ -n "${force}" ] || continue

    t_stdout_is "${want}" "lineage ts=${ts:-<none>} force=${force}" -- \
        pol_lineage_disposition "${ts}" "${NOW}" 2700 120 "${force}"
    t_rc "${rc}" "lineage rc ts=${ts:-<none>} force=${force}" -- \
        pol_lineage_disposition "${ts}" "${NOW}" 2700 120 "${force}"
done <<'TABLE'
20260816T115900Z|0|proceed|0
20260816T115900Z|1|proceed|0
20260816T114500Z|0|proceed|0
20260816T111500Z|0|proceed|0
20260816T111459Z|0|force-only|1
20260816T111459Z|1|proceed-forced|0
20260815T120000Z|0|force-only|1
20260815T120000Z|1|proceed-forced|0
20260816T120000Z|0|proceed|0
20260816T120100Z|0|proceed|0
20260816T120200Z|0|proceed|0
20260816T120201Z|0|force-only|1
20260816T120201Z|1|proceed-forced|0
20260816T130000Z|0|force-only|1
20260816T130000Z|1|proceed-forced|0
|0|abort|1
|1|abort|1
TABLE

# --- the boundaries, named -------------------------------------------------

t_diag "staleness_max 2700 puts the boundary at 20260816T111500Z"
t_diag "skew_tolerance 120 puts the boundary at 20260816T120200Z"

# --- absence is not forceable ---------------------------------------------

t_stdout_is "abort" "no lineage: --force does not conjure a replica" -- \
    pol_lineage_disposition "" "${NOW}" 2700 120 1
t_rc 1 "no lineage: --force still fails" -- \
    pol_lineage_disposition "" "${NOW}" 2700 120 1

# ...and it is the ONLY verdict --force cannot turn into a proceed.
for ts in 20260816T115900Z 20260816T111459Z 20260815T120000Z \
          20260816T130000Z; do
    t_rc 0 "--force proceeds for a replica that exists: ${ts}" -- \
        pol_lineage_disposition "${ts}" "${NOW}" 2700 120 1
done

# --- contract errors -------------------------------------------------------

t_rc 2 "refuses a replica timestamp that is not a timestamp" -- \
    pol_lineage_disposition lastweek "${NOW}" 2700 120 0
t_rc 2 "refuses a non-integer now" -- \
    pol_lineage_disposition 20260816T115900Z soon 2700 120 0
t_rc 2 "refuses a non-integer staleness_max" -- \
    pol_lineage_disposition 20260816T115900Z "${NOW}" lots 120 0
t_rc 2 "refuses a non-integer skew tolerance" -- \
    pol_lineage_disposition 20260816T115900Z "${NOW}" 2700 loose 0
t_rc 2 "refuses a force flag that is not 0 or 1" -- \
    pol_lineage_disposition 20260816T115900Z "${NOW}" 2700 120 yes
t_rc 2 "refuses an empty force flag" -- \
    pol_lineage_disposition 20260816T115900Z "${NOW}" 2700 120 ''
t_stdout_is "" "prints nothing when it refuses" -- \
    pol_lineage_disposition lastweek "${NOW}" 2700 120 0

# --- the verdict vocabulary is closed -------------------------------------
#
# Callers switch on these four words. A fifth appearing without the callers
# being taught it would be a silent fall-through, so the set is asserted.

seen=""
for ts in "" 20260816T115900Z 20260816T111459Z 20260816T130000Z; do
    for f in 0 1; do
        v=$( pol_lineage_disposition "${ts}" "${NOW}" 2700 120 "${f}" ) ||:
        seen="${seen}${v}
"
    done
done
t_is "$( printf '%s' "${seen}" | LC_ALL=C sort -u | tr '\n' ' ' )" \
    "abort force-only proceed proceed-forced " \
    "the verdict vocabulary is exactly the four documented words"

t_done
