#!/bin/sh
# Tier 3 -- verb completeness and doc liveness (TESTING.md §4).
#
# Two directions, one guard:
#
#   every verb in the dispatcher has a section in README.md   -- a verb nobody
#       can find is a verb nobody uses, and the CLI is the product's surface;
#   every 'seance <verb>' README shows exists in the dispatcher -- the "control
#       named in the copy must exist" rule applied to a command line. A README
#       that tells an operator at 03:00 to run a verb that was renamed is worse
#       than a README that says nothing.
#
# THE SHAPES, pinned here because a guard that accepts two shapes accepts
# neither:
#
#   dispatcher  the arms of `case "${_verb}" in` in bin/seance, read AS TEXT.
#               Not from --help: --help is documentation too, and asking the
#               documentation whether it matches the documentation is how a
#               pair of them come to agree with each other and with nothing
#               else. Each arm's alternatives are split on '|'; the '*' arm is
#               the unknown-verb fallback and is not a verb; an alternative
#               beginning with '-' ('--help', '-h') is an option-spelled alias
#               of the arm's first alternative and needs no section of its own,
#               though it may still be shown in README.
#
#   README      a section is a line that is exactly '### seance <verb>'.
#
#   liveness    inside CODE CONTEXT only -- fenced blocks and inline backtick
#               spans -- any 'seance <word>' where <word> starts a verb-shaped
#               token must be a dispatcher alternative. Prose is not scanned:
#               "seance is pure sh" is a sentence, not an invocation, and a
#               guard that cannot tell them apart teaches people to write
#               around it.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

# dispatcher_alternatives <bin/seance>
#
# Every alternative of every arm of the verb case, one per line, in source
# order: config, version, help, --help, -h.
#
# Nested case statements inside an arm are counted and skipped, so that a verb
# whose implementation branches does not contribute its branches to the verb
# list.
dispatcher_alternatives()
{
    awk '
        depth == 0 && /case[ \t]*"\$\{_verb\}"[ \t]*in/ { depth = 1; next }
        depth == 0 { next }
        /(^|[ \t;])case[ \t]/ { depth++; next }
        /(^|[ \t;])esac([ \t;]|$)/ {
            depth--
            if (depth == 0) { exit }
            next
        }
        depth == 1 && match($0, /^[ \t]*[^ \t()]+\)/) {
            label = substr($0, RSTART, RLENGTH - 1)
            sub(/^[ \t]+/, "", label)
            n = split(label, alt, "|")
            for (i = 1; i <= n; i++) { print alt[i] }
        }
    ' "$1"
}

# dispatcher_verbs <bin/seance>
#
# The alternatives that are verbs: not the '*' fallback, not an option-spelled
# alias.
dispatcher_verbs()
{
    dispatcher_alternatives "$1" | awk '
        $0 == "*"     { next }
        /^-/          { next }
        { print }
    '
}

# readme_sections <README.md>  -- the verb named by each '### seance <v>' line.
readme_sections()
{
    sed -n -e 's/^### seance \([a-z0-9-][a-z0-9-]*\)$/\1/p' "$1"
}

# readme_code <README.md>
#
# Every fenced code block line, and every inline backtick span on its own
# line. One span per line on purpose: joining them would let "`seance` and
# `config`" read as the invocation 'seance config'.
readme_code()
{
    awk '
        /^```/ { fence = 1 - fence; next }
        fence  { print; next }
        {
            line = $0
            while (match(line, /`[^`]*`/)) {
                print substr(line, RSTART + 1, RLENGTH - 2)
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$1"
}

# readme_invocations <README.md>
#
# The word after 'seance' in every invocation README shows in code context.
readme_invocations()
{
    readme_code "$1" | awk '
        {
            s = $0
            while (match(s, /(^|[ \t])seance[ \t]+[-a-z0-9][a-z0-9-]*/)) {
                tok = substr(s, RSTART, RLENGTH)
                sub(/^[ \t]*seance[ \t]+/, "", tok)
                print tok
                s = substr(s, RSTART + RLENGTH)
            }
        }
    ' | LC_ALL=C sort -u
}

# missing <list-a> <list-b>  -- the words of A that are not words of B.
missing()
{
    local _a _b _w _out

    _a=$1
    _b=$2
    _out=""

    for _w in ${_a}; do
        case " ${_b} " in
            *" ${_w} "*) continue ;;
        esac
        _out="${_out} ${_w}"
    done

    printf '%s' "${_out# }"
}

# ---------------------------------------------------------------------------
# The guard, over a tree root, so that a mutated copy can be checked too.
# ---------------------------------------------------------------------------

undocumented()
{
    missing "$( dispatcher_verbs "$1/bin/seance" | tr '\n' ' ' )" \
            "$( readme_sections "$1/README.md" | tr '\n' ' ' )"
}

sections_without_verbs()
{
    missing "$( readme_sections "$1/README.md" | tr '\n' ' ' )" \
            "$( dispatcher_verbs "$1/bin/seance" | tr '\n' ' ' )"
}

dead_invocations()
{
    missing "$( readme_invocations "$1/README.md" | tr '\n' ' ' )" \
            "$( dispatcher_alternatives "$1/bin/seance" | tr '\n' ' ' )"
}

# dead_invocations_in <tree> <doc>  -- the same, for any document.
#
# README is not the only file that tells an operator what to type. A drill is
# followed at three in the morning by somebody who did not write it, and
# docs/repl-wire.md is what M2's promotion path is built against; a verb
# renamed out from under either of them is the same rot in a place nobody
# greps.
dead_invocations_in()
{
    missing "$( readme_invocations "$2" | tr '\n' ' ' )" \
            "$( dispatcher_alternatives "$1/bin/seance" | tr '\n' ' ' )"
}

# The documents scanned for liveness beyond README. A file added here and not
# to the repository is caught by the "shows seance being invoked" assertion,
# which is why that assertion is per-document rather than over the union.
DOC_SET="docs/repl-wire.md docs/DRILLS.md docs/RUNBOOK-failback.md"

t_plan 19

verbs=$( dispatcher_verbs "${T_ROOT}/bin/seance" | tr '\n' ' ' )
t_isnt "${verbs}" "" "the dispatcher's verbs can be read out of bin/seance"

sections=$( readme_sections "${T_ROOT}/README.md" | tr '\n' ' ' )
t_isnt "${sections}" "" "README.md has verb sections"

invocations=$( readme_invocations "${T_ROOT}/README.md" | tr '\n' ' ' )
t_isnt "${invocations}" "" "README.md shows seance being invoked"

t_is "$( undocumented "${T_ROOT}" )" "" \
    "every verb in the dispatcher has a '### seance <verb>' section"
t_is "$( sections_without_verbs "${T_ROOT}" )" "" \
    "every '### seance <verb>' section names a verb the dispatcher has"
t_is "$( dead_invocations "${T_ROOT}" )" "" \
    "every seance invocation README shows exists in the dispatcher"

# Mutation checks, permanent. A guard never observed failing has unmeasured
# value, and these three are the exact rots it exists to catch.
scratch=$( t_tmpdir )
mkdir -p "${scratch}/bin"
cp "${T_ROOT}/bin/seance" "${scratch}/bin/seance"
cp "${T_ROOT}/README.md" "${scratch}/README.md"

# A verb grows in the dispatcher and nobody writes it up.
awk '
    { print }
    /case[ \t]*"\$\{_verb\}"[ \t]*in/ && !done {
        print "    exorcise)"
        print "        :"
        print "        ;;"
        done = 1
    }
' "${T_ROOT}/bin/seance" > "${scratch}/bin/seance"

t_is "$( undocumented "${scratch}" )" "exorcise" \
    "a verb with no README section is caught"

cp "${T_ROOT}/bin/seance" "${scratch}/bin/seance"
# shellcheck disable=SC2016
#   The single quotes are the point: the backticks are Markdown being written
#   into a README, not a command substitution to expand.
printf '\n```sh\nseance exorcise --now\n```\n' >> "${scratch}/README.md"

t_is "$( dead_invocations "${scratch}" )" "exorcise" \
    "a README invocation of a verb that does not exist is caught"

# A verb is removed from the dispatcher and its section is left behind.
cp "${T_ROOT}/README.md" "${scratch}/README.md"
printf '\n### seance exorcise\n\nGone, but still written up.\n' \
    >> "${scratch}/README.md"

t_is "$( sections_without_verbs "${scratch}" )" "exorcise" \
    "a README section for a verb the dispatcher does not have is caught"

# ---------------------------------------------------------------------------
# The other documents an operator types out of
# ---------------------------------------------------------------------------

for doc in ${DOC_SET}; do
    t_rc 0 "${doc} is in the repository" -- test -r "${T_ROOT}/${doc}"

    inv=$( readme_invocations "${T_ROOT}/${doc}" | tr '\n' ' ' )
    t_isnt "${inv}" "" "${doc} shows seance being invoked"

    t_is "$( dead_invocations_in "${T_ROOT}" "${T_ROOT}/${doc}" )" "" \
        "every seance invocation ${doc} shows exists in the dispatcher"
done

# The same mutation, in the same place it would really happen: a document that
# goes on telling an operator to run a verb that has been renamed.
cp "${T_ROOT}/docs/DRILLS.md" "${scratch}/DRILLS.md"
# shellcheck disable=SC2016
#   The single quotes are the point: the backticks are Markdown being written
#   into a document, not a command substitution to expand.
printf '\n```sh\nseance exorcise --guest web01\n```\n' >> "${scratch}/DRILLS.md"

t_is "$( dead_invocations_in "${T_ROOT}" "${scratch}/DRILLS.md" )" "exorcise" \
    "a drill step naming a verb that does not exist is caught"

t_done
