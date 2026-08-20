#!/bin/sh
# Tier 3 -- config completeness, both directions (TESTING.md §4).
#
# Every key seance implements is documented in etc/seance.conf.sample, and
# every key the sample documents is one seance implements. A key added to the
# parser and not to the sample is a feature nobody can find; a key left in the
# sample after the parser stopped accepting it is worse, because an operator
# who copies it gets a file that will not load.
#
# The vocabulary is read out of lib/conf.subr AS TEXT -- the guard greps the
# CONF_*_KEYS definitions rather than sourcing the file and echoing the
# variables. Asserting against a re-export is asserting that the file can print
# its own variables; asserting against the source is asserting what the source
# says. The classification of the sample's keys is reimplemented here on
# purpose, small and dumb, so that it is not conf_classify marking its own
# homework.
#
# The sample documents most keys commented out, so the extraction strips a
# leading '#' before looking for <key>=. That is the only thing about the
# sample's shape this guard assumes.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

CONF_SRC="${T_ROOT}/lib/conf.subr"
SAMPLE="${T_ROOT}/etc/seance.conf.sample"

# ---------------------------------------------------------------------------
# Extraction: source text in, space-separated word lists out
# ---------------------------------------------------------------------------

# list_from_source <VARIABLE> <file>
#
# The words of a one-line VARIABLE="a b c" assignment. Prints nothing if the
# assignment is not there, which the first assertions below turn into a
# failure rather than into a guard that passes over an empty list forever.
list_from_source()
{
    sed -n -e "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$2" | tr '\n' ' '
}

# default_rows <file>  -- "key=value" per row of the CONF_DEFAULTS table.
default_rows()
{
    awk '
        /^CONF_DEFAULTS="/ { inside = 1; next }
        inside && /^"/     { inside = 0; next }
        inside && /=/      { print }
    ' "$1"
}

# default_keys <file>  -- the keys of that table, space separated.
default_keys()
{
    default_rows "$1" | sed -e 's/=.*//' | tr '\n' ' '
}

# sample_rows <file>
#
# Every "key=value" the sample mentions, comment marker and indentation
# stripped. This is what makes a sample of commented-out defaults readable as
# documentation by a machine as well as by a person.
sample_rows()
{
    awk '
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            sub(/^#+[ \t]*/, "", line)
            if (line ~ /^[a-z0-9_]+=/) { print line }
        }
    ' "$1"
}

# ---------------------------------------------------------------------------
# Classification: deliberately a second, simpler implementation
# ---------------------------------------------------------------------------

# shape <key>  -- "fleet <key>", "node <field>", "guest <field>", "names", "bad"
shape()
{
    local _k _rest

    _k=$1

    case "${_k}" in
        node_*)
            _rest=${_k#node_}
            [ "${_rest%%_*}" != "${_rest}" ] || { printf 'bad\n'; return 0; }
            printf 'node %s\n' "${_rest#*_}"
            ;;
        guest_*)
            _rest=${_k#guest_}
            [ "${_rest%%_*}" != "${_rest}" ] || { printf 'bad\n'; return 0; }
            printf 'guest %s\n' "${_rest#*_}"
            ;;
        names_*) printf 'names\n' ;;
        *)       printf 'fleet %s\n' "${_k}" ;;
    esac
}

# ---------------------------------------------------------------------------
# Set operations over space-separated word lists
# ---------------------------------------------------------------------------

# contains <list> <word>
contains()
{
    case " $1 " in
        *" $2 "*) return 0 ;;
    esac

    return 1
}

# missing_from <list-a> <list-b>  -- the words of a that b does not have.
missing_from()
{
    local _b _w _out

    _b=$2
    _out=""

    # shellcheck disable=SC2086
    #   Deliberate word splitting: both arguments are space-separated lists of
    #   [a-z0-9_]+ words extracted from source text, so no element can contain
    #   whitespace or a glob character.
    set -- $1

    for _w in "$@"; do
        contains "${_b}" "${_w}" || _out="${_out} ${_w}"
    done

    printf '%s\n' "${_out}"
}

# sample_value <key>  -- what the sample documents for that key, if anything.
sample_value()
{
    printf '%s\n' "${SROWS}" |
        awk -v want="$1" -F= '
            $1 == want { i = index($0, "="); print substr($0, i + 1); exit }
        '
}

# wrong_defaults <defaults-rows>
#
# The keys whose documented value in the sample is not the value the code
# actually defaults to. A default changed in code and not in the sample is a
# lie in the one file an operator reads before touching anything.
wrong_defaults()
{
    local _row _k _v _s _out

    _out=""

    printf '%s\n' "$1" > "${WORK}/defaults"
    while IFS= read -r _row; do
        [ -n "${_row}" ] || continue
        _k=${_row%%=*}
        _v=${_row#*=}
        _s=$( sample_value "${_k}" )
        [ "${_s}" = "${_v}" ] || _out="${_out} ${_k}"
    done < "${WORK}/defaults"

    printf '%s\n' "${_out}"
}

# ---------------------------------------------------------------------------
# Doc liveness: a document that names a key seance no longer has
# ---------------------------------------------------------------------------
#
# The sample is not the only file that names configuration keys, and a
# document naming one that has been renamed is the same rot as a README naming
# a verb that has been renamed -- worse, because the operator's edit will then
# be refused by conf_load with "unknown key" at three in the morning.
#
# The scan is deliberately narrow and stated: a backticked span, OUTSIDE fenced
# code blocks, that is entirely lowercase-with-underscores. In these documents
# such a token is a configuration key -- with two exceptions, each of which has
# to be subtracted rather than tolerated, because each is real.
#
#   1. seance's own shell functions have the same shape (`repl_standby_root`
#      beside `standby_root`). The subtraction is computed from the source
#      rather than written out here, so that a new function cannot quietly
#      become a new exception.
#
#   2. THE HOST'S OWN VARIABLES. From M3 seance prescribes host configuration
#      it does not own (design §1: "seance verifies CARP, it does not own it"),
#      so its documents have to be able to name rc.conf(5)'s and
#      loader.conf(5)'s variables. This list is written out, not computed,
#      because it is exactly the set of foreign names the documents may use and
#      the point is that it stays small: a name added to it is a name this
#      guard stops checking, so adding one is a decision and not a convenience.
#      Every entry is a variable of the base system, cited where it is used.
DOC_FOREIGN_VARS="kld_list carp_load"

DOC_SET="docs/repl-wire.md docs/DRILLS.md docs/RUNBOOK-failback.md README.md"

# doc_key_tokens <file>
doc_key_tokens()
{
    awk '
        /^```/ { fence = 1 - fence; next }
        fence  { next }
        {
            line = $0
            while (match(line, /`[^`]*`/)) {
                print substr(line, RSTART + 1, RLENGTH - 2)
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$1" | grep -E '^[a-z][a-z0-9]*(_[a-z0-9]+)+$' | LC_ALL=C sort -u
}

# lib_functions -- every shell function lib/ defines, space separated.
lib_functions()
{
    sed -n -e 's/^\([a-z_][a-z0-9_]*\)()$/\1/p' "${T_ROOT}"/lib/*.subr |
        LC_ALL=C sort -u | tr '\n' ' '
}

# unknown_doc_keys <file> <fleet> <node-fields> <guest-fields> <functions>
#
# The tokens that are neither a function, nor a variable of the host's own
# configuration, nor a key of any shape seance knows.
#
# A BARE node or guest field counts as known. Prose names a key the way a
# person says it -- "this node's auto_promote" -- and the prefixed spelling is
# a fact about where it lives in the file, not about whether seance has it. The
# question this guard asks is whether the document names something that exists,
# and node_<key>_auto_promote existing is the answer to it.
unknown_doc_keys()
{
    local _file _fleet _node _guest _fn _tok _rest _out

    _file=$1
    _fleet=$2
    _node=$3
    _guest=$4
    _fn=$5
    _out=""

    for _tok in $( doc_key_tokens "${_file}" ); do
        contains "${_fn}" "${_tok}" && continue
        contains "${DOC_FOREIGN_VARS}" "${_tok}" && continue

        case "${_tok}" in
            node_*)
                _rest=${_tok#node_}
                contains "${_node}" "${_rest#*_}" && continue
                ;;
            guest_*)
                _rest=${_tok#guest_}
                contains "${_guest}" "${_rest#*_}" && continue
                ;;
            names_*)
                continue
                ;;
            *)
                contains "${_fleet}" "${_tok}" && continue
                contains "${_node}" "${_tok}" && continue
                contains "${_guest}" "${_tok}" && continue
                ;;
        esac

        _out="${_out} ${_tok}"
    done

    printf '%s\n' "${_out}"
}

WORK=$( t_tmpdir )

FLEET=$( list_from_source CONF_FLEET_KEYS "${CONF_SRC}" )
NODEK=$( list_from_source CONF_NODE_KEYS "${CONF_SRC}" )
GUESTK=$( list_from_source CONF_GUEST_KEYS "${CONF_SRC}" )
DERIVED=$( list_from_source CONF_DERIVED_KEYS "${CONF_SRC}" )
RUNTIME=$( list_from_source CONF_RUNTIME_KEYS "${CONF_SRC}" )
DEFKEYS=$( default_keys "${CONF_SRC}" )
DEFROWS=$( default_rows "${CONF_SRC}" )

SROWS=$( sample_rows "${SAMPLE}" )

# What the sample says, by shape.
S_FLEET=""
S_NODE=""
S_GUEST=""
S_NAMES=0
S_BAD=""

# Read row by row from a file, never by word-splitting: a documented value may
# contain spaces (ssh_extra_opts does), and splitting on whitespace would turn
# the second half of one into a key of its own.
sample_rows "${SAMPLE}" > "${WORK}/sample.rows"
while IFS= read -r row; do
    [ -n "${row}" ] || continue
    k=${row%%=*}
    case "$( shape "${k}" )" in
        'fleet '*) S_FLEET="${S_FLEET} ${k}" ;;
        'node '*)  S_NODE="${S_NODE} $( shape "${k}" | sed -e 's/^node //' )" ;;
        'guest '*) S_GUEST="${S_GUEST} $( shape "${k}" | sed -e 's/^guest //' )" ;;
        names)     S_NAMES=1 ;;
        *)         S_BAD="${S_BAD} ${k}" ;;
    esac
done < "${WORK}/sample.rows"

t_plan 35

# --- the guard is scanning something ---------------------------------------

t_isnt "${FLEET}" "" "CONF_FLEET_KEYS was found in lib/conf.subr"
t_isnt "${NODEK}" "" "CONF_NODE_KEYS was found in lib/conf.subr"
t_isnt "${SROWS}" "" "etc/seance.conf.sample mentions some keys"
t_is "${S_BAD}" "" "every key in the sample has a recognisable shape"

# --- fleet keys, both directions -------------------------------------------

t_is "$( missing_from "${FLEET}" "${S_FLEET}" )" "" \
    "every implemented fleet key is documented in the sample"
t_is "$( missing_from "${S_FLEET}" "${FLEET}" )" "" \
    "every fleet key in the sample is implemented"

# --- node fields, both directions ------------------------------------------

t_is "$( missing_from "${NODEK}" "${S_NODE}" )" "" \
    "every implemented node field is documented in the sample"
t_is "$( missing_from "${S_NODE}" "${NODEK}" )" "" \
    "every node field in the sample is implemented"

# --- guest fields, both directions -----------------------------------------

t_is "$( missing_from "${GUESTK}" "${S_GUEST}" )" "" \
    "every guest-overridable key is documented in the sample"
t_is "$( missing_from "${S_GUEST}" "${GUESTK}" )" "" \
    "every guest key in the sample is guest-overridable"

t_is "${S_NAMES}" "1" "the display-name mapping is documented in the sample"

# --- the vocabulary lists are internally consistent ------------------------

t_is "$( missing_from "${DEFKEYS}" "${FLEET}" )" "" \
    "every key with a default is a fleet key"
t_is "$( missing_from "${DERIVED} ${RUNTIME}" "${FLEET}" )" "" \
    "every derived or runtime key is a fleet key"

# A key cannot be two kinds of unset at once: a static default, a derivation
# and a runtime lookup are three different answers to the same question.
clash=""
for k in ${DERIVED} ${RUNTIME}; do
    contains "${DEFKEYS}" "${k}" && clash="${clash} ${k}"
done
t_is "${clash}" "" "no key has both a static default and a derivation"

clash=""
for k in ${DERIVED}; do
    contains "${RUNTIME}" "${k}" && clash="${clash} ${k}"
done
t_is "${clash}" "" "no key is both derived and runtime-resolved"

# --- the documented defaults are the real defaults -------------------------

t_is "$( wrong_defaults "${DEFROWS}" )" "" \
    "the sample documents each default with its real value"

# --- the sample is a working file ------------------------------------------

t_rc 0 "the sample parses" -- \
    sh "${T_ROOT}/bin/seance" config --file "${SAMPLE}" --check
t_stdout_is "PASS" "the sample passes the check" -- \
    sh "${T_ROOT}/bin/seance" config --file "${SAMPLE}" --check

# --- mutation checks, permanent --------------------------------------------
#
# A guard never observed failing has unmeasured value, so each direction is
# broken on a scratch copy and required to complain.

MUT="${WORK}/conf.subr"

# (a) a key implemented but not documented
sed -e 's/^CONF_FLEET_KEYS="cadence /CONF_FLEET_KEYS="cadence brandnewkey /' \
    "${CONF_SRC}" > "${MUT}"
t_is "$( missing_from "$( list_from_source CONF_FLEET_KEYS "${MUT}" )" \
                      "${S_FLEET}" )" " brandnewkey" \
    "mutation: an implemented-but-undocumented key is caught"

# (b) a key documented but not implemented
cp "${SAMPLE}" "${WORK}/sample.conf"
printf 'brandnewkey=1\n' >> "${WORK}/sample.conf"
mut_fleet=""
sample_rows "${WORK}/sample.conf" > "${WORK}/mut.rows"
while IFS= read -r row; do
    [ -n "${row}" ] || continue
    k=${row%%=*}
    case "$( shape "${k}" )" in
        'fleet '*) mut_fleet="${mut_fleet} ${k}" ;;
    esac
done < "${WORK}/mut.rows"
t_is "$( missing_from "${mut_fleet}" "${FLEET}" )" " brandnewkey" \
    "mutation: a documented-but-unimplemented key is caught"

# (c) a default changed in code and not in the sample
sed -e 's/^cadence=900$/cadence=600/' "${CONF_SRC}" > "${MUT}"
t_is "$( wrong_defaults "$( default_rows "${MUT}" )" )" " cadence" \
    "mutation: a default changed in code but not in the sample is caught"

# (d) a node field implemented but not documented
sed -e 's/^CONF_NODE_KEYS="nodename /CONF_NODE_KEYS="nodename newfield /' \
    "${CONF_SRC}" > "${MUT}"
t_is "$( missing_from "$( list_from_source CONF_NODE_KEYS "${MUT}" )" \
                      "${S_NODE}" )" " newfield" \
    "mutation: an undocumented node field is caught"

# --- doc liveness ----------------------------------------------------------

FUNCS=$( lib_functions )
t_isnt "${FUNCS}" "" "lib/ defines functions, so the subtraction is real"

for doc in ${DOC_SET}; do
    t_is "$( unknown_doc_keys "${T_ROOT}/${doc}" \
            "${FLEET}" "${NODEK}" "${GUESTK}" "${FUNCS}" )" "" \
        "every configuration key ${doc} names is one seance knows"
done

# The mutation: a document goes on naming a key that has been renamed.
cp "${T_ROOT}/docs/repl-wire.md" "${WORK}/repl-wire.md"
# shellcheck disable=SC2016
#   The single quotes are the point: the backticks are Markdown being written
#   into a document, not a command substitution to expand.
printf '\nThe fleet key `standby_rooot` is where replicas land.\n' \
    >> "${WORK}/repl-wire.md"
t_is "$( unknown_doc_keys "${WORK}/repl-wire.md" \
        "${FLEET}" "${NODEK}" "${GUESTK}" "${FUNCS}" )" " standby_rooot" \
    "mutation: a document naming a key that does not exist is caught"

# The two allowances are allowances and not holes: a MISSPELT node field and a
# MISSPELT foreign variable are both still caught, which is what makes them
# subtractions of exactly what they name.
cp "${T_ROOT}/docs/repl-wire.md" "${WORK}/allow.md"
# shellcheck disable=SC2016
#   As above: Markdown being written into a document, not shell to expand.
printf '\nThis node names `auto_promote` and `kld_list`, and also `auto_promot` and `kld_lst`.\n' \
    >> "${WORK}/allow.md"
t_is "$( unknown_doc_keys "${WORK}/allow.md" \
        "${FLEET}" "${NODEK}" "${GUESTK}" "${FUNCS}" )" " auto_promot kld_lst" \
    "mutation: a bare node field and a foreign variable pass, and their typos do not"

t_isnt "${DOC_FOREIGN_VARS}" "" \
    "the foreign-variable allowance is a list, and it is written down here"

# ---------------------------------------------------------------------------
# The README's configuration reference is COMPLETE
# ---------------------------------------------------------------------------
#
# The doc-liveness scan above asks whether every key a document NAMES exists.
# This asks the other direction of the one document that claims to be a
# reference: README carries a table of every fleet key, every per-node field
# and every per-guest field, and a key that seance implements and README does
# not list is a key an operator cannot find. The sample has the same promise
# and is checked for it at the top of this file; README is where somebody
# looks first.
#
# The tokens are harvested WITHOUT the underscore requirement the liveness scan
# uses, because a node field is a bare word (`nodename`, `mgmt`, `heir`) and
# would otherwise be invisible to the harvest that finds `retention_recent`.

readme_tokens()
{
    awk '
        {
            line = $0
            while (match(line, /`[^`]*`/)) {
                print substr(line, RSTART + 1, RLENGTH - 2)
                line = substr(line, RSTART + RLENGTH)
            }
        }
    ' "$1" | grep -E '^[a-z][a-z0-9_]*$' | LC_ALL=C sort -u | tr '\n' ' '
}

RTOK=$( readme_tokens "${T_ROOT}/README.md" )
t_isnt "${RTOK}" "" "README.md names configuration keys in backticks"

t_is "$( missing_from "${FLEET}" "${RTOK}" )" "" \
    "README.md's reference lists every fleet key"
t_is "$( missing_from "${NODEK}" "${RTOK}" )" "" \
    "and every per-node field"
t_is "$( missing_from "${GUESTK}" "${RTOK}" )" "" \
    "and every per-guest-overridable key"

# The mutation: a key seance implements and README does not mention.
t_is "$( missing_from "${FLEET} brandnewkey" "${RTOK}" )" " brandnewkey" \
    "mutation: a key README does not list is caught"

t_done
