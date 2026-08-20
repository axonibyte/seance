#!/bin/sh
# Tier 3 -- M2's documents, read as data (TESTING.md §4).
#
# t_verb_docs.sh asks whether the VERBS a document names exist. This file asks
# the same question of the three other things an M2 document tells an operator
# to type or to expect, none of which is a verb:
#
#   * `--force=<rung>`. The rung names are a closed vocabulary
#     (PROMOTE_FORCEABLE), and a document naming one that promote_parse_force
#     would reject is a document that sends somebody to a usage error in the
#     middle of an outage. Both directions: every name the docs show must be
#     one the parser knows, and every forceable rung must be written down
#     somewhere -- a rung nobody documents is a lever nobody finds at 03:00.
#   * The EVIDENCE tokens that go into succession.log. They are the record's
#     wire format, quoted in README and in the runbook as `fence:<driver>`,
#     `force:<operator>`, `failback` and `discard:<bytes>`, and they are
#     written by exactly four printf statements.
#   * The VERDICT LINES quoted in a runbook. A runbook that shows an operator
#     the message they will see is only useful while that is the message they
#     will see. The source writes those lines with printf formats, so a
#     whole-line comparison could only be fuzzy; what is compared instead is
#     every LITERAL SEGMENT of the quoted line -- the runs of text between the
#     `<placeholders>` -- each of which must appear verbatim in the source.
#     That covers the whole sentence rather than its head, and it is where the
#     rot shows: a renamed verdict, a re-worded refusal, a colon that moved.
#     A quoted verdict must therefore be written with `<guest>` rather than
#     with an example name, which is better documentation anyway.
#
# Every check below counts what it checked and asserts the count, because a
# guard that silently finds nothing to check is a guard that has been turned
# off by a change of Markdown style.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

DOCS="${T_ROOT}/README.md ${T_ROOT}/docs/DRILLS.md ${T_ROOT}/docs/RUNBOOK-failback.md ${T_ROOT}/docs/repl-wire.md"
SRC="${T_ROOT}/lib/promote.subr ${T_ROOT}/lib/failback.subr ${T_ROOT}/lib/gate.subr ${T_ROOT}/lib/repl.subr ${T_ROOT}/lib/status.subr ${T_ROOT}/lib/verify.subr ${T_ROOT}/lib/conf.subr ${T_ROOT}/bin/seance"

# forceable  -- the rung names --force accepts, from the source of truth.
forceable()
{
    sed -n -e 's/^PROMOTE_FORCEABLE="\(.*\)"$/\1/p' "${T_ROOT}/lib/promote.subr"
}

# doc_force_names  -- every --force=<name> any document shows, deduplicated.
doc_force_names()
{
    # shellcheck disable=SC2086
    #   Deliberate word splitting: ${DOCS} is a list of paths.
    grep -ho -- '--force=[abcdefghijklmnopqrstuvwxyz]*' ${DOCS} |
        sed -e 's/^--force=//' | grep . | LC_ALL=C sort -u
}

t_plan 16

# ---------------------------------------------------------------------------
# --force's vocabulary
# ---------------------------------------------------------------------------

FORCEABLE=$( forceable )
t_is "${FORCEABLE}" "quorum fence lineage kernel" \
    "the forceable rungs are read out of lib/promote.subr, not written down here"

NAMES=$( doc_force_names | tr '\n' ' ' )
t_isnt "${NAMES}" "" "the documents show --force being used"

# `probes` is the one name a document may show that the parser refuses, and it
# shows it in order to say so: "a host that answers is never fenced by force"
# (D-44 item 1). A guard that failed on it would be a guard that stopped the
# README explaining the one rung that cannot be forced -- so it is allowed here
# only because the parser has an explicit refusal for it, which the next
# assertion checks is still there.
UNKNOWN=""
for n in ${NAMES}; do
    case " ${FORCEABLE} probes " in
        *" ${n} "*) ;;
        *) UNKNOWN="${UNKNOWN} ${n}" ;;
    esac
done
t_is "${UNKNOWN# }" "" \
    "every --force=<rung> the documents show is a rung promote_parse_force knows"

t_like "$( cat "${T_ROOT}/lib/promote.subr" )" '\[ "\$\{_r\}" = "probes" \]' \
    "and 'probes' is refused by name in the parser, which is why the docs may show it"

MISSING=""
for r in ${FORCEABLE}; do
    # shellcheck disable=SC2086
    #   Deliberate word splitting: ${DOCS} is a list of paths.
    grep -q -- "--force=${r}\|\`${r}\`" ${DOCS} || MISSING="${MISSING} ${r}"
done
t_is "${MISSING# }" "" \
    "and every forceable rung is named in the documents: a lever nobody wrote down is a lever nobody finds"

# The mutation: a rung that exists nowhere in the source.
SCRATCH=$( t_tmpdir )
printf 'seance promote alpha --force=exorcise\n' > "${SCRATCH}/doc.md"
BOGUS=$( grep -ho -- '--force=[abcdefghijklmnopqrstuvwxyz]*' "${SCRATCH}/doc.md" |
    sed -e 's/^--force=//' )
UNKNOWN=""
for n in ${BOGUS}; do
    case " ${FORCEABLE} probes " in
        *" ${n} "*) ;;
        *) UNKNOWN="${UNKNOWN} ${n}" ;;
    esac
done
t_is "${UNKNOWN# }" "exorcise" \
    "a document naming a rung that does not exist is caught"

# ---------------------------------------------------------------------------
# The evidence tokens, which are succession.log's wire format
# ---------------------------------------------------------------------------

t_like "$( cat "${T_ROOT}/lib/promote.subr" )" 'PROMOTE_EVIDENCE="fence:\$\{_driver\}"' \
    "fence:<driver> is written by promote's fence rung"
t_like "$( cat "${T_ROOT}/lib/promote.subr" )" 'PROMOTE_EVIDENCE="force:\$\{PROMOTE_OPERATOR\}"' \
    "force:<operator> is written when a human accepted what could not be confirmed"
t_like "$( cat "${T_ROOT}/lib/failback.subr" )" '_evidence="discard:\$\{_total\}"' \
    "discard:<bytes> is written by failback when the operator accepted the loss"
t_like "$( cat "${T_ROOT}/lib/failback.subr" )" '_evidence=failback' \
    "and a plain failback is its own evidence"

# ---------------------------------------------------------------------------
# The verdict lines a runbook quotes
# ---------------------------------------------------------------------------

# quoted_verdicts <doc>  -- every line inside a fenced block that begins with a
# verb name and a colon: the shape of a verdict line (D-55).
quoted_verdicts()
{
    awk '
        /^```/ { inblk = !inblk; next }
        !inblk { next }
        /^(seance|repl|status|verify|config|promote|failback|failback-assist|gate|placement|adapter): / { print }
    ' "$1"
}

# segments_of <line>  -- the literal runs of a quoted verdict: the line with
# every `<placeholder>` and every run of digits removed, one segment per line.
# Those are the parts the source writes literally; the rest is a printf
# conversion or an operator's own guest name.
segments_of()
{
    printf '%s\n' "$1" |
        sed -e 's/<[abcdefghijklmnopqrstuvwxyz_-]*>/\n/g' -e 's/[0-9][0-9]*/\n/g' |
        tr '\\n' '\n'
}

CHECKED=0
DEAD=""
for d in ${DOCS}; do
    quoted_verdicts "${d}" > "${SCRATCH}/v" || : > "${SCRATCH}/v"
    while IFS= read -r line || [ -n "${line}" ]; do
        [ -n "${line}" ] || continue
        segments_of "${line}" > "${SCRATCH}/seg"
        while IFS= read -r seg || [ -n "${seg}" ]; do
            # A segment of a handful of characters would match anything, and a
            # quoted verdict that short is not evidence either way.
            [ "${#seg}" -ge 8 ] || continue
            CHECKED=$(( CHECKED + 1 ))
            # shellcheck disable=SC2086
            #   Deliberate word splitting: ${SRC} is a list of paths.
            grep -Fq -- "${seg}" ${SRC} || DEAD="${DEAD}
${d##*/}: ${seg}"
        done < "${SCRATCH}/seg"
    done < "${SCRATCH}/v"
done

t_is "${DEAD}" "" \
    "every verdict line quoted in a document is still written, verbatim, by the source"
if [ "${CHECKED}" -ge 10 ]; then
    t_ok "and there were ${CHECKED} of them to check: the guard is not scanning an empty set"
else
    t_not_ok "and there were ${CHECKED} of them to check: the guard is not scanning an empty set"
fi

# ---------------------------------------------------------------------------
# The mesh link, which is a command every install document tells an operator
# to type and which named the wrong file until M5
# ---------------------------------------------------------------------------
#
# `seance placement` is what one node runs on another over ssh, and it is
# reached through a link on the ssh user's PATH. The link has to be the
# module's VERB WRAPPER -- the `seance` file at the module root -- because the
# dispatcher under bin/ is not told which node it is on (D-2). Linked to
# bin/seance it answers `no config file` and exits 2, which every reader of a
# placement query treats as a peer that COULD NOT REPORT (D-96): the gate then
# withholds whole estates, `promote` aborts and `failback` refuses, fleet-wide,
# because of an install instruction. Measured in the guest at M5; both forms
# were run, and only the wrapper answered.
#
# The check is over CODE CONTEXT only, like every other guard here: prose that
# says "not bin/seance" is the documentation doing its job.

LINKDOCS="${T_ROOT}/README.md ${T_ROOT}/docs/INSTALL.md ${T_ROOT}/docs/RUNBOOK-failback.md ${T_ROOT}/docs/DRILLS.md"

# ln_targets <doc>  -- the source path of every `ln -s <src> <dst>` a document
# shows in a fenced block or a backtick span.
ln_targets()
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
    ' "$1" | awk '$1 == "ln" { for (i = 2; i <= NF; i++) if ($i !~ /^-/) { print $i; break } }'
}

BADLINK=""
LINKS=0
for d in ${LINKDOCS}; do
    for tgt in $( ln_targets "${d}" ); do
        LINKS=$(( LINKS + 1 ))
        case "${tgt}" in
            */bin/seance) BADLINK="${BADLINK} ${d##*/}:${tgt}" ;;
        esac
    done
done

t_is "${BADLINK}" "" \
    "no document tells an operator to link bin/seance onto the mesh's PATH"
if [ "${LINKS}" -ge 1 ]; then
    t_ok "and there were ${LINKS} 'ln' command(s) to check: the guard is not scanning an empty set"
else
    t_not_ok "and there were ${LINKS} 'ln' command(s) to check: the guard is not scanning an empty set"
fi

# The mutation: the instruction as it was written before M5.
# shellcheck disable=SC2016
#   The single quotes are the point: this is Markdown source being written.
printf '```sh\nln -s /usr/local/cbsd/modules/seance.d/bin/seance /usr/local/bin/seance\n```\n' \
    > "${SCRATCH}/link.md"
t_isnt "$( ln_targets "${SCRATCH}/link.md" | grep -c '/bin/seance$' )" "0" \
    "a document that links bin/seance is caught"

# The mutation: a runbook that quotes a message nobody prints any more.
# shellcheck disable=SC2016
#   The single quotes are the point: this is the source text of a Markdown
#   document being written, not an expansion for this shell.
printf '```\nfailback: RECONSIDERED -- the guest has thought better of it\n```\n' \
    > "${SCRATCH}/rot.md"
p=$( quoted_verdicts "${SCRATCH}/rot.md" )
# shellcheck disable=SC2086
#   Deliberate word splitting: ${SRC} is a list of paths.
if grep -Fq -- "${p}" ${SRC}; then
    t_not_ok "a quoted verdict the source does not print is caught"
else
    t_ok "a quoted verdict the source does not print is caught"
fi

t_done
