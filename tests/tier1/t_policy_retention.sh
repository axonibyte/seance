#!/bin/sh
# Tier 1 -- the retention ladder (TESTING.md §2, design §4).
#
# Retention decides what gets destroyed, on the source and on every replica
# alike, so its boundaries are the ones worth being pedantic about: an age
# exactly equal to retention_recent is recent, one second more falls to the
# hourly rung, an age exactly equal to retention_hourly is still eligible for
# its hour, and one second more is gone.
#
# Two properties matter beyond the table. Keep and prune must partition the
# input exactly -- every input timestamp appears in one list or the other and
# never in both, because a name that falls out of both is a leak and a name in
# both is a contradiction. And an input line that does not parse must stop the
# whole thing: a name we did not understand must never reach the prune list by
# default.
#
# The functions read stdin, so the assertions here run the pipeline and compare
# the captured result rather than going through t_stdout_is. A pipeline's exit
# status is its last command's, and the policy function is always last, so the
# status captured is the one that matters.
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

NOW=$( pol_ts_to_epoch 20260816T120000Z )

# keep <recent> <hourly> <ts...>  -- print what survives.
keep()
{
    local _r _h

    _r=$1
    _h=$2
    shift 2

    printf '%s\n' "$@" | pol_retention_keep "${NOW}" "${_r}" "${_h}"
}

# prune <recent> <hourly> <ts...>  -- print what goes.
prune()
{
    local _r _h

    _r=$1
    _h=$2
    shift 2

    printf '%s\n' "$@" | pol_retention_prune "${NOW}" "${_r}" "${_h}"
}

# guarded <protected-file> <recent> <hourly> <ts...>
guarded()
{
    local _p _r _h

    _p=$1
    _r=$2
    _h=$3
    shift 3

    printf '%s\n' "$@" |
        pol_retention_prune_protected "${NOW}" "${_r}" "${_h}" "${_p}"
}

# The working set for the middle of this file: noon, a recent window of an
# hour and an hourly window of three, so the recent boundary sits at 11:00:00Z
# and the hourly boundary at 09:00:00Z.
SET="20260816T120000Z 20260816T114500Z 20260816T110000Z
20260816T104500Z 20260816T103000Z 20260816T101500Z 20260816T100000Z
20260816T094500Z 20260816T090000Z 20260816T085959Z 20260815T120000Z"

# shellcheck disable=SC2086
#   Deliberate word splitting: ${SET} is a whitespace-separated list of
#   timestamps, none of which can contain whitespace or a glob character.
set -- ${SET}
KEPT=$( keep 3600 10800 "$@" )
PRUNED=$( prune 3600 10800 "$@" )

t_plan 29

# --- the four boundaries ---------------------------------------------------

t_is "$( keep 3600 10800 20260816T110000Z )" "20260816T110000Z" \
    "boundary: age exactly retention_recent is kept as recent"
t_is "$( keep 3600 10800 20260816T105959Z )" "20260816T105959Z" \
    "boundary: recent+1s survives as its hour's newest"
t_is "$( keep 3600 10800 20260816T090000Z )" "20260816T090000Z" \
    "boundary: age exactly retention_hourly is still eligible"
t_is "$( keep 3600 10800 20260816T085959Z )" "" \
    "boundary: one second past retention_hourly is dropped"
t_is "$( prune 3600 10800 20260816T085959Z )" "20260816T085959Z" \
    "boundary: one second past retention_hourly is pruned"

# --- the hourly rung keeps the newest of each hour, not the first ----------

t_is "${KEPT}" "20260816T094500Z
20260816T104500Z
20260816T110000Z
20260816T114500Z
20260816T120000Z" "the hourly rung keeps the newest of each hour"

t_is "${PRUNED}" "20260815T120000Z
20260816T085959Z
20260816T090000Z
20260816T100000Z
20260816T101500Z
20260816T103000Z" "prune is the complement"

# --- keep and prune partition the input exactly ---------------------------

t_is "$( { printf '%s\n' "${KEPT}"; printf '%s\n' "${PRUNED}"; } |
         LC_ALL=C sort )" \
     "$( printf '%s\n' "$@" | LC_ALL=C sort -u )" \
     "keep and prune partition the input exactly"

t_is "$( { printf '%s\n' "${KEPT}"; printf '%s\n' "${PRUNED}"; } |
         LC_ALL=C sort | uniq -d )" "" \
     "no timestamp is both kept and pruned"

# Every kept timestamp really was one of the inputs: retention selects, it
# never synthesises.
SETSP=" $* "
strays=""
for k in ${KEPT}; do
    case "${SETSP}" in
        *" ${k} "*) ;;
        *) strays="${strays} ${k}" ;;
    esac
done
t_is "${strays}" "" "retention invents no timestamps"

# --- order, duplicates, and empty input -----------------------------------

t_is "$( keep 3600 10800 20260816T100000Z 20260816T120000Z \
                         20260816T110000Z 20260816T120000Z \
                         20260816T100000Z )" \
     "20260816T100000Z
20260816T110000Z
20260816T120000Z" \
     "output is ascending and de-duplicated whatever the input order"

t_is "$( printf '' | pol_retention_keep "${NOW}" 3600 10800 )" "" \
    "empty input keeps nothing"
printf '' | pol_retention_keep "${NOW}" 3600 10800 > /dev/null
t_is "$?" "0" "empty input is not an error"
t_is "$( printf '' | pol_retention_prune "${NOW}" 3600 10800 )" "" \
    "empty input prunes nothing"

t_is "$( printf '20260816T120000Z' |
         pol_retention_keep "${NOW}" 3600 10800 )" "20260816T120000Z" \
    "a last line without a newline is read"

# --- an unparsable line stops everything ----------------------------------

printf '20260816T120000Z\nzzz\n' | pol_retention_keep "${NOW}" 3600 10800 \
    > /dev/null
t_is "$?" "2" "keep refuses a line that is not a timestamp"

out=$( printf '20260816T120000Z\nzzz\n' |
       pol_retention_prune "${NOW}" 3600 10800 )
t_is "$?" "2" "prune refuses a line that is not a timestamp"
t_is "${out}" "" "prune prints nothing at all when a line does not parse"

printf '' | pol_retention_keep soon 3600 10800 > /dev/null
t_is "$?" "2" "keep refuses a non-integer now"
printf '' | pol_retention_keep "${NOW}" lots 10800 > /dev/null
t_is "$?" "2" "keep refuses a non-integer retention_recent"
printf '' | pol_retention_keep "${NOW}" 3600 lots > /dev/null
t_is "$?" "2" "keep refuses a non-integer retention_hourly"

# --- a snapshot from the future is kept, never pruned ---------------------
#
# Retention's job is to destroy things. A timestamp we already know is the
# product of arithmetic gone wrong is the last thing it should destroy, so a
# future timestamp counts as age zero here and the skew is diagnosed by
# pol_age at its real tolerance, in status.

t_is "$( keep 3600 10800 20260816T130000Z )" "20260816T130000Z" \
    "a future timestamp is kept"
t_is "$( prune 3600 10800 20260816T130000Z )" "" \
    "a future timestamp is never pruned"

# --- the protected list ----------------------------------------------------
#
# The newest snapshot a peer has acknowledged is the base of the next
# incremental send. Pruning it because it aged out turns the next tick into a
# full resend and can break the lineage promotion reads, so repl passes it
# through and retention obeys without asking why.

DIR=$( t_tmpdir )
printf '20260816T100000Z\n20260816T101500Z\n' > "${DIR}/protected"

t_is "$( guarded "${DIR}/protected" 3600 10800 "$@" )" "20260815T120000Z
20260816T085959Z
20260816T090000Z
20260816T103000Z" "a protected timestamp is never pruned"

t_is "$( guarded "" 3600 10800 "$@" )" "${PRUNED}" \
    "an empty protected path protects nothing"
t_is "$( guarded "${DIR}/absent" 3600 10800 "$@" )" "${PRUNED}" \
    "an absent protected file protects nothing"

printf '%s\n' "$@" > "${DIR}/all"
t_is "$( guarded "${DIR}/all" 3600 10800 "$@" )" "" \
    "protecting everything prunes nothing"

# --- the band boundary and the hour boundary are different things ---------
#
# An hour bucket whose newer members are already "recent" must still yield its
# newest hourly-band member: not nothing, and not the recent one twice.

t_is "$( keep 3600 10800 20260816T113000Z 20260816T110500Z \
                         20260816T105900Z 20260816T105000Z )" \
     "20260816T105900Z
20260816T110500Z
20260816T113000Z" \
     "a bucket straddling the recent boundary yields both bands"

# --- a zero-length recent window -------------------------------------------

t_is "$( keep 0 10800 20260816T120000Z 20260816T115900Z \
                      20260816T115800Z )" \
     "20260816T115900Z
20260816T120000Z" \
     "with retention_recent 0 only now and each hour's newest survive"

t_done
