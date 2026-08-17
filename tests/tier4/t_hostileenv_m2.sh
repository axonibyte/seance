#!/bin/sh
# Tier 4 -- M2's records and verdicts under a hostile locale and time zone.
#
# TESTING.md §3 has the vectors run twice, "once normally, once under LC_ALL=C
# vs a UTF-8 locale and under TZ set to a non-UTC zone -- because timestamps
# are UTC-always by spec, and the suite must fail if an implementation
# accidentally localizes". M1's loop did that for `status` and `verify` in the
# guest. This file does it for what M2 writes, which is the half that outlives
# the terminal: the succession record, the placement file, and the promotion
# ladder's own verdicts.
#
# THE TWO HOSTILE ENVIRONMENTS, and why these:
#
#   tr_TR.UTF-8 + Asia/Kathmandu   Turkish collates and cases differently from
#                                  C (the dotless i is the classic way an
#                                  ASCII-looking comparison goes wrong), and
#                                  Kathmandu is +05:45 -- an offset that is not
#                                  a whole number of hours, so a timestamp that
#                                  went through local time cannot be mistaken
#                                  for a UTC one that happens to be off by a
#                                  round amount.
#   de_DE.UTF-8 + America/Sao_Paulo   a comma decimal separator and a zone on
#                                  the other side of UTC, so a sign error looks
#                                  different from a rounding one.
#
# WHAT IS ASSERTED, in one sentence: the bytes. Not "it still works" -- the
# records written and the lines printed must be identical to the ones the C
# locale in UTC produces, because those bytes are a wire protocol that another
# node's parser reads.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

DIR=$( t_tmpdir )

# A fixed instant, so that nothing here depends on when it runs:
# 1767225600 == 2026-01-01T00:00:00Z, which is 05:45 on the 1st in Kathmandu
# and 21:00 on the previous day in Sao Paulo. A timestamp rendered in either
# local zone is unmistakable.
EPOCH=1767225600
WANT_TS=20260101T000000Z

# The environments, one per line: "<label> <LC_ALL> <TZ>".
ENVS="c LC_ALL=C TZ=UTC
tr LC_ALL=tr_TR.UTF-8 TZ=Asia/Kathmandu
de LC_ALL=de_DE.UTF-8 TZ=America/Sao_Paulo"

# probe <LC_ALL=...> <TZ=...>
#
# One run of every M2 record-writing and record-rendering path, in a fresh
# state directory, in a child shell with that environment. Everything it prints
# is data: the caller compares the whole transcript, byte for byte.
probe()
{
    # shellcheck disable=SC2016
    #   The single quotes are the point: what follows is the source text of the
    #   probe script, and it must be expanded by the CHILD shell -- the one
    #   running in the hostile environment -- and not by this one.
    env -u LANG -u LC_CTYPE -u LC_COLLATE -u LC_TIME "$1" "$2" \
        SEANCE_STATE_DIR="${DIR}/state.$3" \
        /bin/sh -eu -c '
        R=$1
        E=$2
        mkdir -p "${SEANCE_STATE_DIR}"

        . "${R}/lib/common.subr"
        . "${R}/lib/policy.subr"
        . "${R}/lib/conf.subr"
        . "${R}/lib/transport.subr"
        . "${R}/lib/notify.subr"
        . "${R}/lib/zfs.subr"
        . "${R}/lib/lineage.subr"
        . "${R}/lib/repl.subr"
        . "${R}/lib/status.subr"
        . "${R}/lib/gate.subr"
        . "${R}/lib/promote.subr"

        # --- the rendered instant -------------------------------------------
        TS=$( pol_epoch_to_ts "${E}" )
        printf "ts\t%s\n" "${TS}"
        printf "roundtrip\t%s\n" "$( pol_ts_to_epoch "${TS}" )"
        printf "snap\t%s\n" "$( pol_snap_format alpha "${TS}" )"
        printf "parse\t%s\n" "$( pol_snap_parse "$( pol_snap_format alpha "${TS}" )" )"
        printf "age\t%s\n" "$( status_age_human 9412 )"
        printf "cmp\t%s\n" "$( pol_snap_cmp "${TS}" 20251231T235959Z )"

        # --- the succession record, which another node reads ----------------
        promote_record web01 alpha bravo "${E}" fence:mock
        promote_record db01 alpha bravo "${E}" "force:o.brien"
        printf "record\t%s\n" "$( cat "${SEANCE_STATE_DIR}/succession.log" )"

        # --- the placement file, and the order it comes back in -------------
        placement_set web01 alpha
        placement_set arc01 charlie
        placement_set db01 charlie
        printf "placement\t%s\n" "$( placement_local | tr "\n" "|" )"
        printf "home\t%s\n" "$( placement_home arc01 )"

        # --- retention, whose selection is a sort ---------------------------
        printf "%s\n" 20260101T000000Z 20251231T235959Z 20251201T000000Z \
            20250101T000000Z |
            pol_retention_prune "${E}" 14400 172800 |
            tr "\n" "|" |
            sed -e "s/^/prune\t/" -e "s/$/\n/"
    ' seance-hostile-probe "${T_ROOT}" "${EPOCH}"
}

t_plan 13

# ---------------------------------------------------------------------------
# The bytes, in three environments
# ---------------------------------------------------------------------------

printf '%s\n' "${ENVS}" | while IFS=' ' read -r label lc tz; do
    [ -n "${label}" ] || continue
    probe "${lc}" "${tz}" "${label}" > "${DIR}/out.${label}" 2> "${DIR}/err.${label}"
done

C_OUT=$( cat "${DIR}/out.c" )

t_isnt "${C_OUT}" "" "the C/UTC probe produced a transcript to compare against"
t_like "${C_OUT}" "^ts	${WANT_TS}\$" \
    "and it renders the fixed instant as the UTC timestamp the spec pins"

for label in tr de; do
    if [ ! -s "${DIR}/out.${label}" ]; then
        t_not_ok "the ${label} probe ran (locale present, no crash)"
        sed -e 's/^/# /' "${DIR}/err.${label}" 2>/dev/null
        continue
    fi
    t_ok "the ${label} probe ran (locale present, no crash)"
done

for label in tr de; do
    if diff -u "${DIR}/out.c" "${DIR}/out.${label}" > "${DIR}/diff.${label}" 2>&1; then
        t_ok "${label}: every M2 record and rendering is byte-identical to C/UTC"
    else
        t_not_ok "${label}: every M2 record and rendering is byte-identical to C/UTC"
        sed -e 's/^/# /' "${DIR}/diff.${label}"
    fi
done

# The two that would be wrong in a way a diff of two hostile runs could not
# catch -- both hostile environments localising the same way -- are pinned
# against the constant instead.
t_like "$( cat "${DIR}/out.tr" )" "^ts	${WANT_TS}\$" \
    "the Kathmandu run's timestamp is the UTC one, not 05:45 on the same day"
t_like "$( cat "${DIR}/out.de" )" "^record	web01	alpha	bravo	${WANT_TS}	fence:mock" \
    "and the Sao Paulo run's succession record carries the UTC instant, five fields, in order"

# Compared as a STRING and not as a pattern: the field is pipe-separated, and
# a pipe in an extended regular expression is an alternation -- an assertion
# written that way would have matched anything at all, including nothing.
t_is "$( awk '/^placement\t/ { sub(/^placement\t/, ""); print }' "${DIR}/out.tr" )" \
    "web01	alpha|arc01	charlie|db01	charlie|" \
    "the placement file reads back in the order it was written, whatever the collation table says"

t_is "$( awk -F '\t' '$1 == "prune" { print $2 }' "${DIR}/out.tr" )" \
    "$( awk -F '\t' '$1 == "prune" { print $2 }' "${DIR}/out.c" )" \
    "and retention selects the same snapshots for destruction, which is the sort that matters most"

# ---------------------------------------------------------------------------
# The ladder and the failback, end to end, in the hostile environment
#
# The transcripts above are the records. These are the verbs: the whole tier-4
# truth table and the whole failback fixture, re-run under tr_TR.UTF-8 in
# Kathmandu. Their own assertions are the assertions; what is checked here is
# that every one of them still holds, and that the count is the same, so that a
# file which silently ran fewer rows would be caught too.
# ---------------------------------------------------------------------------

result_of()
{
    awk '/^# result / { print $3 " " $4 " " $5 }' "$1"
}

for f in t_ladder t_failback t_records; do
    sh "${T_ROOT}/tests/tier4/${f}.sh" > "${DIR}/${f}.native" 2>&1
    env LC_ALL=tr_TR.UTF-8 TZ=Asia/Kathmandu \
        sh "${T_ROOT}/tests/tier4/${f}.sh" > "${DIR}/${f}.hostile" 2>&1
    hrc=$?

    native=$( result_of "${DIR}/${f}.native" )
    hostile=$( result_of "${DIR}/${f}.hostile" )

    if [ "${hrc}" -eq 0 ] && [ "${native}" = "${hostile}" ] && [ -n "${native}" ]; then
        t_ok "${f}.sh under tr_TR.UTF-8 in Kathmandu: ${hostile} (same as native)"
    else
        t_not_ok "${f}.sh under tr_TR.UTF-8 in Kathmandu: ${hostile} (native ${native})"
        grep -E '^not ok' "${DIR}/${f}.hostile" | sed -e 's/^/# /'
    fi
done

t_done
