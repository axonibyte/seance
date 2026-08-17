#!/bin/sh
# Tier 3 -- every bsddialog call site in lib/setup.subr maps to an answers key
# (TESTING.md §4, design §14, handoff's model-selection note on M5).
#
# `seance setup`'s whole claim is that the interactive wizard is a thin layer
# over the same answers a headless run takes with --set/--answers (D-3's
# "inter=0 culture", carried into M5): tier 1 proves that claim behaviourally
# for the headless half (t_setup_headless.sh), which is all a workstation CAN
# prove -- bsddialog needs a real terminal and there is no script(1) harness
# for it here. This file is the other half, and it is deliberately dumb:
# source as data, like every other tier-3 guard, because a clever call site is
# exactly what a guard like this cannot be reasoned around.
#
# THE CONTRACT, read out of lib/setup.subr's own header: every
# `bsddialog --stdout` invocation is immediately preceded by a tag comment --
# possibly wrapped over more than one line, in which case the tag is on the
# FIRST line of that contiguous comment block -- naming either:
#
#   # setup-answer: <key> [<key> ...]
#       the literal seance.conf key(s) this screen sets: bare for a fleet key,
#       `node:<field>` for a per-node field, `guest:<field>` for a per-guest
#       field, or one of the structural names `node-select`, `guest-select`,
#       `names` (screens that pick a key or set a display name rather than a
#       config value).
#   # setup-nodata: <why>
#       this screen stores nothing (an orientation screen, a "continue?"
#       confirmation, a read-only preview) -- still tagged, because an
#       untagged call site is what this guard exists to catch, not merely an
#       untagged DATA call site.
#
# Two directions, both asserted: every call site is tagged with something the
# vocabulary recognises (so the wizard never silently asks a question with no
# non-interactive equivalent), and every fleet/node/guest key IS asked
# somewhere (so the wizard can actually produce a complete configuration).
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SETUP_SRC="${T_ROOT}/lib/setup.subr"
CONF_SRC="${T_ROOT}/lib/conf.subr"

STRUCTURAL="names node-select guest-select"

# ---------------------------------------------------------------------------
# Extraction
# ---------------------------------------------------------------------------

# list_from_source <VARIABLE> <file>  -- same idiom as t_config_keys.sh: read
# the vocabulary out of conf.subr's own CONF_*_KEYS="..." line, as text.
list_from_source()
{
    sed -n -e "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$2" | tr '\n' ' '
}

# call_site_tags <file>
#
# One line per `bsddialog --stdout` call site, in file order: the text of the
# tag comment immediately above it (leading '#' and whitespace stripped), or
# an EMPTY line if there is none. A comment line does not itself count as a
# call site -- this file's own header talks about bsddialog invocations in
# prose, inside backticks, and must not be mistaken for one.
call_site_tags()
{
    awk '
        /bsddialog --stdout/ && !/^[ \t]*#/ {
            t = blockfirst
            sub(/^[ \t]*#[ \t]*/, "", t)
            print t
            blockfirst = ""
            next
        }
        /^[ \t]*#/ {
            if (!incomment) { blockfirst = $0; incomment = 1 }
            next
        }
        /^[ \t]*$/ { incomment = 0; next }
        { incomment = 0 }
    ' "$1"
}

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

# contains <list> <word>
contains()
{
    case " $1 " in
        *" $2 "*) return 0 ;;
    esac

    return 1
}

# key_known <key> <fleet> <node-fields> <guest-fields>  -- rc 0 if <key> is a
# recognised answer key: a bare fleet key, node:<field>, guest:<field>, or one
# of the structural names.
key_known()
{
    local _key _fleet _node _guest _field

    _key=$1
    _fleet=$2
    _node=$3
    _guest=$4

    case "${_key}" in
        node:*)
            _field=${_key#node:}
            contains "${_node}" "${_field}"
            return $?
            ;;
        guest:*)
            _field=${_key#guest:}
            contains "${_guest}" "${_field}"
            return $?
            ;;
        *)
            contains "${_fleet}" "${_key}" && return 0
            contains "${STRUCTURAL}" "${_key}"
            return $?
            ;;
    esac
}

# untagged_sites <file>  -- the tag text of every call site that is NOT one of
# the two recognised shapes (empty, or neither setup-answer: nor setup-nodata:
# prefixed), one per line.
untagged_sites()
{
    call_site_tags "$1" | awk '
        $0 !~ /^setup-answer: / && $0 !~ /^setup-nodata: / { print "[" $0 "]" }
    '
}

# unknown_answer_keys <file> <fleet> <node-fields> <guest-fields>  -- every key
# named by a setup-answer: tag that key_known refuses, space separated.
unknown_answer_keys()
{
    local _file _fleet _node _guest _tag _k _out

    _file=$1
    _fleet=$2
    _node=$3
    _guest=$4
    _out=""

    call_site_tags "${_file}" | while IFS= read -r _tag; do
        case "${_tag}" in
            'setup-answer: '*)
                for _k in ${_tag#setup-answer: }; do
                    key_known "${_k}" "${_fleet}" "${_node}" "${_guest}" ||
                        printf '%s\n' "${_k}"
                done
                ;;
        esac
    done
}

# uncovered_keys <file> <keys> <prefix>  -- the members of <keys> that no
# setup-answer: tag names, given as bare words (<prefix> empty) or
# "<prefix>:<field>" (<prefix> "node" or "guest").
uncovered_keys()
{
    local _file _keys _prefix _tags _k _want _out

    _file=$1
    _keys=$2
    _prefix=$3
    _out=""

    _tags=$( call_site_tags "${_file}" | grep '^setup-answer: ' )

    for _k in ${_keys}; do
        if [ -n "${_prefix}" ]; then
            _want="${_prefix}:${_k}"
        else
            _want=${_k}
        fi

        printf '%s\n' "${_tags}" | grep -Eq "(^| )${_want}( |\$)" ||
            _out="${_out} ${_want}"
    done

    printf '%s\n' "${_out# }"
}

FLEET=$( list_from_source CONF_FLEET_KEYS "${CONF_SRC}" )
NODEK=$( list_from_source CONF_NODE_KEYS "${CONF_SRC}" )
GUESTK=$( list_from_source CONF_GUEST_KEYS "${CONF_SRC}" )

t_plan 13

# --- the guard is scanning something ----------------------------------------

SITES=$( call_site_tags "${SETUP_SRC}" )
SITE_COUNT=$( printf '%s\n' "${SITES}" | grep -c . )
t_isnt "${SITE_COUNT}" "0" "lib/setup.subr has bsddialog call sites to check"
if [ "${SITE_COUNT}" -ge 30 ]; then
    t_ok "and there are at least 30 of them (one per fleet/node/guest field, plus flow)"
else
    t_not_ok "and there are at least 30 of them (one per fleet/node/guest field, plus flow)"
fi

t_isnt "${FLEET}" "" "CONF_FLEET_KEYS was found in lib/conf.subr"
t_isnt "${NODEK}" "" "CONF_NODE_KEYS was found in lib/conf.subr"
t_isnt "${GUESTK}" "" "CONF_GUEST_KEYS was found in lib/conf.subr"

# --- every call site is tagged, and with one of the two recognised shapes --

t_is "$( untagged_sites "${SETUP_SRC}" )" "" \
    "every bsddialog call site has a 'setup-answer:' or 'setup-nodata:' tag"

# --- every setup-answer: tag names a key setup could actually write --------

t_is "$( unknown_answer_keys "${SETUP_SRC}" "${FLEET}" "${NODEK}" "${GUESTK}" | tr '\n' ' ' )" "" \
    "every setup-answer key is a real fleet/node/guest key, or a structural name"

# --- every real key is asked somewhere --------------------------------------

t_is "$( uncovered_keys "${SETUP_SRC}" "${FLEET}" "" )" "" \
    "every fleet key has a setup-answer: tag somewhere"
t_is "$( uncovered_keys "${SETUP_SRC}" "${NODEK}" "node" )" "" \
    "every per-node field has a setup-answer: tag somewhere"
t_is "$( uncovered_keys "${SETUP_SRC}" "${GUESTK}" "guest" )" "" \
    "every per-guest field has a setup-answer: tag somewhere"

# ---------------------------------------------------------------------------
# Mutation checks, permanent: a guard never observed failing has unmeasured
# value, and these are the exact three rots this file exists to catch.
# ---------------------------------------------------------------------------

SCRATCH=$( t_tmpdir )/setup.subr

# (a) a bsddialog call site with no tag at all.
cp "${SETUP_SRC}" "${SCRATCH}"
# shellcheck disable=SC2016
#   The single quotes are the point: this is source text being appended to a
#   scratch copy of lib/setup.subr, not a command substitution to expand here.
printf '\nsetup_ask_exorcise()\n{\n    local _v\n    _v=$( bsddialog --stdout --title "x" --inputbox "x" 0 0 "" )\n}\n' \
    >> "${SCRATCH}"
t_isnt "$( untagged_sites "${SCRATCH}" )" "" \
    "mutation: an untagged bsddialog call site is caught"

# (b) a setup-answer: tag naming a key that does not exist.
cp "${SETUP_SRC}" "${SCRATCH}"
# shellcheck disable=SC2016
#   As above: source text being appended, not an expansion.
printf '\nsetup_ask_exorcise()\n{\n    local _v\n    # setup-answer: brandnewkey\n    _v=$( bsddialog --stdout --title "x" --inputbox "x" 0 0 "" )\n}\n' \
    >> "${SCRATCH}"
t_is "$( unknown_answer_keys "${SCRATCH}" "${FLEET}" "${NODEK}" "${GUESTK}" | tr '\n' ' ' )" \
    "brandnewkey " \
    "mutation: a setup-answer tag naming an unknown key is caught"

# (c) a key that setup can no longer ask about (its only tag renamed away).
sed -e 's/# setup-answer: witness$/# setup-answer: wutness/' \
    "${SETUP_SRC}" > "${SCRATCH}"
t_is "$( uncovered_keys "${SCRATCH}" "${FLEET}" "" )" "witness" \
    "mutation: a fleet key with no remaining setup-answer tag is caught"

t_done
