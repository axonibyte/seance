#!/bin/sh
# Tier 3 -- the rediscovery battery, read as data.
#
# TESTING.md §8 is the methodology's acceptance test: revert each protection
# this project has already paid for once, and require the harness to
# rediscover it. `tests/rediscovery/table.tsv` is that list made runnable, and
# it costs a reaper session to run -- tier 6 is root, ZFS and vnet jails, tier
# 7 is half an hour a seed. So the things that can go wrong with the battery
# BETWEEN those sessions are exactly the things nothing notices:
#
#   * a protection §8 names loses its row, and the acceptance test quietly
#     stops covering it;
#   * a patch stops applying, because the code it reverts moved. run.sh calls
#     that a FAIL when it is run -- months later, in a session somebody is
#     paying for;
#   * a row names a test file, a tier or a stage that does not exist;
#   * a tier-7 row loses the seed and step count that ARE the row (D-143,
#     D-148): run against another window it reverts a protection its trace
#     never reaches, and passes while proving nothing.
#
# All four are answerable in milliseconds on a workstation, from the files
# themselves. That is what this file does: it is a guard over the guard.
#
# THE MAP FROM §8's PROSE TO A PATCH FILE LIVES HERE, in the test, for the same
# reason the tenant guard's forbidden list does (D-15): §8 is a committed spec
# copy (D-11) written in English, and the mapping is a claim about this
# repository that has to be somewhere a change can break.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

TABLE="${T_ROOT}/tests/rediscovery/table.tsv"
TESTING="${T_ROOT}/TESTING.md"
STAGES="${T_ROOT}/tests/cluster/lib/stage.subr"

TAB=$( printf '\t.' )
TAB=${TAB%.}

# Every protection TESTING.md §8 names, as <marker-in-the-prose>=<patch-file>.
# The marker is a fixed string from that row's first column, distinctive enough
# to identify the row and short enough to survive an edit of its wording.
SECTION8='-x mountpoint=recv-no-x-mountpoint.patch
promotion without fencing=promotion-without-fencing.patch
masks its own crash=verifier-masks-crash.patch
stale-lineage promotion=stale-lineage-no-threshold.patch
quorum rule removed=quorum-rule-removed.patch
boot gate removed=boot-gate-removed.patch'

# rows  -- the data rows of the table: comments and the header dropped.
rows()
{
    awk -F "${TAB}" '
        /^[ \t]*#/ { next }
        NF == 0 { next }
        $1 == "patch-file" { next }
        { print }
    ' "${TABLE}"
}

t_plan 15

# ---------------------------------------------------------------------------
# The table's own shape
# ---------------------------------------------------------------------------

t_rc 0 "the table is readable" -- test -r "${TABLE}"

HEADER=$( awk '/^patch-file/ { print; exit }' "${TABLE}" )
t_is "${HEADER}" "patch-file${TAB}tier${TAB}stage${TAB}test${TAB}env" \
    "the header names five tab-separated columns, env last (D-148)"

NROWS=$( rows | awk 'END { print NR + 0 }' )
t_rc 0 "and the table has rows in it (${NROWS})" -- test "${NROWS}" -gt 0

BADFIELDS=$( rows | awk -F "${TAB}" 'NF < 4 || NF > 5 { print NR ": " NF " fields" }' )
t_is "${BADFIELDS}" "" \
    "every row has four fields or five: the env column is optional and nothing else is"

# ---------------------------------------------------------------------------
# Every protection TESTING.md §8 names has a row
# ---------------------------------------------------------------------------

MISSING_PROSE=""
MISSING_ROW=""
MISSING_PATCH=""
CHECKED=0

OIFS=$IFS
IFS='
'
# shellcheck disable=SC2086
#   Deliberate word splitting on newline: one mapping per element.
for pair in ${SECTION8}; do
    IFS=$OIFS

    marker=${pair%%=*}
    patch=${pair##*=}
    CHECKED=$(( CHECKED + 1 ))

    grep -Fq -- "${marker}" "${TESTING}" ||
        MISSING_PROSE="${MISSING_PROSE} [${marker}]"

    [ -r "${T_ROOT}/tests/rediscovery/${patch}" ] ||
        MISSING_PATCH="${MISSING_PATCH} ${patch}"

    rows | awk -F "${TAB}" -v p="${patch}" '$1 == p { found = 1 }
        END { exit(found ? 0 : 1) }' ||
        MISSING_ROW="${MISSING_ROW} ${patch}"

    IFS='
'
done
IFS=$OIFS

t_rc 0 "the map covers every row of TESTING.md §8's table (${CHECKED})" \
    -- test "${CHECKED}" -eq 6
t_is "${MISSING_PROSE}" "" \
    "and every marker in it is still in TESTING.md: a spec row that was reworded away is a map that has drifted"
t_is "${MISSING_PATCH}" "" \
    "every protection §8 names has a patch that reverts it"
t_is "${MISSING_ROW}" "" \
    "and at least one row of table.tsv runs it"

# ---------------------------------------------------------------------------
# Every row is runnable: the patch, the test, the tier, the stage
# ---------------------------------------------------------------------------

NOPATCH=""
NOTEST=""
BADTIER=""
BADSTAGE=""
NOAPPLY=""
NOENV=""
NPATCHES=0

STAGE_KNOWN_LINE=$( awk '/^STAGE_KNOWN=/ { print; exit }' "${STAGES}" )

IFS='
'
# shellcheck disable=SC2086
#   Deliberate word splitting on newline: one table row per element.
for row in $( rows ); do
    IFS=$OIFS

    patch=$( printf '%s' "${row}" | awk -F "${TAB}" '{ print $1 }' )
    tier=$( printf '%s' "${row}" | awk -F "${TAB}" '{ print $2 }' )
    stage=$( printf '%s' "${row}" | awk -F "${TAB}" '{ print $3 }' )
    file=$( printf '%s' "${row}" | awk -F "${TAB}" '{ print $4 }' )
    renv=$( printf '%s' "${row}" | awk -F "${TAB}" '{ print $5 }' )

    if [ -r "${T_ROOT}/tests/rediscovery/${patch}" ]; then
        NPATCHES=$(( NPATCHES + 1 ))

        # THE ROW THIS FILE EXISTS FOR. --dry-run is patch(1)'s own answer to
        # "would this apply", and it writes nothing: the tree is read, never
        # touched, which is why this can run on a workstation on every edit
        # instead of in the session that would otherwise discover it.
        ( cd "${T_ROOT}" && patch -p1 --dry-run -s -f < "tests/rediscovery/${patch}" ) \
            > /dev/null 2>&1 ||
            NOAPPLY="${NOAPPLY} ${patch}"
    else
        NOPATCH="${NOPATCH} ${patch}"
    fi

    [ -r "${T_ROOT}/${file}" ] || NOTEST="${NOTEST} ${file}"

    case "${tier}" in
        4|6|7) ;;
        *) BADTIER="${BADTIER} ${patch}:${tier}" ;;
    esac

    case "${tier}:${stage}" in
        4:-) ;;
        4:*) BADSTAGE="${BADSTAGE} ${patch}:tier4-has-a-stage" ;;
        *)
            case " ${STAGE_KNOWN_LINE} " in
                *" ${stage} "*|*"\"${stage} "*|*" ${stage}\""*|*"\"${stage}\""*) ;;
                *) BADSTAGE="${BADSTAGE} ${patch}:${stage}" ;;
            esac
            ;;
    esac

    # A tier-7 row's window is part of the row (D-143): the seed names the one
    # trace that reaches the protection, and 60 steps a seed is half an hour.
    if [ "${tier}" = "7" ]; then
        case "${renv}" in
            *SEANCE_SIM_SEEDS=*) ;;
            *) NOENV="${NOENV} ${patch}:no-seed" ;;
        esac
        case "${renv}" in
            *SEANCE_SIM_STEPS=*) ;;
            *) NOENV="${NOENV} ${patch}:no-step-count" ;;
        esac
    fi

    IFS='
'
done
IFS=$OIFS

t_is "${NOPATCH}" "" "every row names a patch file that exists"
t_rc 0 "and the patches were actually read (${NPATCHES} rows)" \
    -- test "${NPATCHES}" -gt 8
t_is "${NOAPPLY}" "" \
    "every patch still applies to the tree as it stands (patch --dry-run)"
t_is "${NOTEST}" "" "every row names a test file that exists"
t_is "${BADTIER}" "" "every row names a tier the runner has (4, 6 or 7)"
t_is "${BADSTAGE}" "" \
    "every tier-6/7 row names a stage stage.subr knows, and every tier-4 row names none"
t_is "${NOENV}" "" \
    "and every tier-7 row carries its own seed and step count, which ARE the row (D-143, D-148)"

t_done
