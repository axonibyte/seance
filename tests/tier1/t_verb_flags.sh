#!/bin/sh
# Tier 1 -- a property over the CLI: the usage text names every flag the
# dispatcher accepts, and accepts every flag it names.
#
# Source-as-data, over bin/seance, in both directions -- because the two
# failures are different and only one of them is visible from a terminal:
#
#   a flag the parser accepts and the usage does not name is a lever an
#       operator cannot find at 03:00, and it is how `--locked` came to be
#       explained in README and nowhere the operator would type `--help`;
#   a flag the usage names and the parser does not accept sends somebody to
#       "unknown argument" in the middle of an outage -- the same rot
#       tests/tier3/t_verb_docs.sh catches for VERBS, one level down.
#
# It is a property rather than a list: nothing here writes down which flags
# exist, so a flag added to a verb's parser fails this file until the usage
# text grows with it, and a usage line that grows a flag fails until the parser
# does.
#
# WHAT IS READ, and why the shapes are pinned here rather than guessed:
#
#   the parser   the `--flag)` arms of the `case "$1" in` inside each
#                `seance_<verb>()` function in bin/seance, read AS TEXT. The
#                `--flag=*)` spelling is the same flag and is folded into it.
#   the usage    the block of `seance_usage`'s heredoc that begins with the
#                verb's own name at two spaces of indent and runs to the next
#                such line. Per verb rather than over the whole text, so that
#                `--check` documented under `config` cannot stand in for
#                `--check` under `gate`.
#
# ONE BLOCK IS SKIPPED, and it is stated rather than filtered quietly: `help,
# --help, -h`. Those are not flags of a verb -- they are option-spelled
# spellings of the verb itself, they are dispatcher case-arm alternatives, and
# tests/tier3/t_verb_docs.sh already checks them against the dispatcher in both
# directions.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SEANCE="${T_ROOT}/bin/seance"
DIR=$( t_tmpdir )

# parser_flags <bin/seance>  -- "<verb> <flag>" per line.
#
# The function name is the verb: seance_promote_event() is `promote-event`,
# which is the name the dispatcher's case arm and the usage both use.
parser_flags()
{
    awk '
        /^seance_[a-z_]*\(\)$/ {
            fn = $0
            sub(/\(\)$/, "", fn)
            sub(/^seance_/, "", fn)
            gsub(/_/, "-", fn)
            infn = 1
            next
        }
        infn && /^}$/ { infn = 0; next }
        infn && match($0, /^[ \t]*--[^ \t()]*\)/) {
            label = substr($0, RSTART, RLENGTH - 1)
            sub(/^[ \t]+/, "", label)
            n = split(label, a, "|")
            for (i = 1; i <= n; i++) {
                f = a[i]
                sub(/=\*$/, "", f)
                if (f ~ /^--/) { print fn, f }
            }
        }
    ' "$1" | LC_ALL=C sort -u
}

# usage_block <bin/seance> <verb>  -- the lines of the usage text that belong
# to one verb.
usage_block()
{
    awk -v want="$2" '
        /^usage: seance/ { inusage = 1; next }
        !inusage { next }
        /^EOF$/ { exit }
        /^  [a-z]/ {
            name = $1
            sub(/,$/, "", name)
            here = (name == want)
            if (here) { print }
            next
        }
        here { print }
    ' "$1"
}

# usage_flags <bin/seance> <verb>  -- every --flag the verb's block shows.
usage_flags()
{
    usage_block "$1" "$2" |
        grep -oE -- '--[a-z][a-z-]*' | LC_ALL=C sort -u
}

# verbs_with_flags <bin/seance>  -- every verb whose parser takes a flag.
verbs_with_flags()
{
    parser_flags "$1" | awk '{ print $1 }' | LC_ALL=C sort -u
}

t_plan 12

PARSED=$( parser_flags "${SEANCE}" )
t_isnt "${PARSED}" "" "the dispatcher's per-verb flags can be read out of bin/seance"

VERBS=$( verbs_with_flags "${SEANCE}" | tr '\n' ' ' )
t_isnt "${VERBS}" "" "and there is more than one verb that takes flags"

t_isnt "$( usage_block "${SEANCE}" repl )" "" \
    "the usage text can be read back per verb"

# ---------------------------------------------------------------------------
# Direction 1: every flag the parser accepts is named in that verb's usage
# ---------------------------------------------------------------------------

UNDOC=""
printf '%s\n' "${PARSED}" > "${DIR}/parsed"
while IFS=' ' read -r v f; do
    [ -n "${v}" ] || continue
    if ! usage_flags "${SEANCE}" "${v}" | grep -qx -- "${f}"; then
        UNDOC="${UNDOC} ${v}:${f}"
    fi
done < "${DIR}/parsed"

t_is "${UNDOC}" "" \
    "every flag a verb's parser accepts is named in that verb's own usage block"

# ---------------------------------------------------------------------------
# Direction 2: every flag the usage names is one that verb's parser accepts
# ---------------------------------------------------------------------------

DEAD=""
for v in ${VERBS}; do
    for f in $( usage_flags "${SEANCE}" "${v}" ); do
        printf '%s\n' "${PARSED}" | grep -qx -- "${v} ${f}" ||
            DEAD="${DEAD} ${v}:${f}"
    done
done

t_is "${DEAD}" "" \
    "and every flag a verb's usage block names is one its parser accepts"

# ---------------------------------------------------------------------------
# The property is checked against something, not against an empty set
# ---------------------------------------------------------------------------

COUNT=$( printf '%s\n' "${PARSED}" | grep -c . )
if [ "${COUNT}" -ge 15 ]; then
    t_ok "there were ${COUNT} verb/flag pairs to check: the property is not vacuous"
else
    t_not_ok "there were ${COUNT} verb/flag pairs to check: the property is not vacuous"
fi

# The flag this file was written for: internal, explained in README, and until
# M5 absent from the one place an operator types to find out what a verb takes.
REPL_FLAGS=$( usage_flags "${SEANCE}" repl | tr '\n' ' ' )
t_like "${REPL_FLAGS}" '(^| )--locked( |$)' \
    "repl's internal --locked is named in its usage block, not only in README"

# ---------------------------------------------------------------------------
# Mutation checks, permanent
# ---------------------------------------------------------------------------

MUT="${DIR}/seance"

# (a) a verb grows a flag and the usage does not.
awk '
    { print }
    /^            --now\) _now=1 ;;$/ && !done { print "            --exorcise) _x=1 ;;"; done = 1 }
' "${SEANCE}" > "${MUT}"
t_like "$( parser_flags "${MUT}" | tr '\n' ' ' )" 'repl --exorcise' \
    "mutation: a flag added to a parser is seen"
MUTUNDOC=""
parser_flags "${MUT}" > "${DIR}/mut-parsed"
while IFS=' ' read -r v f; do
    [ -n "${v}" ] || continue
    usage_flags "${MUT}" "${v}" | grep -qx -- "${f}" || MUTUNDOC="${MUTUNDOC} ${v}:${f}"
done < "${DIR}/mut-parsed"
t_is "${MUTUNDOC}" " repl:--exorcise" \
    "and a flag the usage does not name is caught"

# (b) the usage names a flag no parser accepts.
sed -e 's/^  status \[--tsv\]/  status [--tsv] [--exorcise]/' "${SEANCE}" > "${MUT}"
MUTDEAD=""
for f in $( usage_flags "${MUT}" status ); do
    parser_flags "${MUT}" | grep -qx -- "status ${f}" || MUTDEAD="${MUTDEAD} status:${f}"
done
t_is "${MUTDEAD}" " status:--exorcise" \
    "mutation: a usage line that names a flag nobody accepts is caught"

# (c) the per-verb blocking is real: --check under config does not cover
# --check under gate.
sed -e 's/^  gate \[--check\] \[--release <guest>\]/  gate [--release <guest>]/' \
    "${SEANCE}" > "${MUT}"
MUTUNDOC=""
parser_flags "${MUT}" > "${DIR}/mut-parsed"
while IFS=' ' read -r v f; do
    [ -n "${v}" ] || continue
    usage_flags "${MUT}" "${v}" | grep -qx -- "${f}" || MUTUNDOC="${MUTUNDOC} ${v}:${f}"
done < "${DIR}/mut-parsed"
t_is "${MUTUNDOC}" " gate:--check" \
    "mutation: a flag documented under another verb does not stand in for this one"

# The two directions are not the same check, and this is the row that says so:
# the mutation above leaves `--check` documented (under config) and still
# fails, which is the whole reason usage_flags takes a verb.
t_like "$( usage_flags "${MUT}" config | tr '\n' ' ' )" '(^| )--check( |$)' \
    "and --check really is still documented under config in that mutated copy"

t_done
