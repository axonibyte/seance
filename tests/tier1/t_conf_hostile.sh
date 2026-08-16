#!/bin/sh
# Tier 1 -- the config parser against input nobody meant to write.
#
# t_conf_parse.sh covers the grammar an operator gets wrong on purpose: a
# missing '=', a capital, a duplicate, CRLF. This file covers the input that
# arrives without anybody deciding to write it -- a byte-order mark left by an
# editor, a value pasted out of a terminal in a UTF-8 locale, a line that looks
# blank and is three tabs, a value four thousand characters long, a key that is
# a prefix of another key, and a fleet of forty nodes rather than three.
#
# Two of these are load-bearing rather than decorative:
#
#   * a value is TEXT. It may contain '=', '#', a backslash, a non-ASCII byte,
#     and the literal text of another key=value record, and none of that may
#     reach the store as anything but bytes. The store is one flat string of
#     newline-joined records, so "a value that looks like a record" is exactly
#     the injection this file is here to refuse.
#   * a list membership test must test membership of ONE word. A
#     space-separated list contains any run of its own words, so a heir naming
#     two nodes at once ("node_alpha_heir=bravo charlie") would otherwise
#     validate as a configured node and then word-split into two heirs in
#     repl_peers -- a fleet replicating to a node the operator never named,
#     with a clean 'config --check'.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/conf.subr
. "${T_ROOT}/lib/conf.subr"

DIR=$( t_tmpdir )

# write <name> -- read the file body from stdin, print the path.
write()
{
    cat > "${DIR}/$1"
    printf '%s\n' "${DIR}/$1"
}

# errs <file> -- load it, print stderr with the directory prefix stripped.
errs()
{
    conf_load "$1" 2>&1 >/dev/null | sed -e "s#^${DIR}/##"
}

t_plan 33

# ---------------------------------------------------------------------------
# A value is text: '=', '#', backslashes, non-ASCII, and record-shaped strings
# ---------------------------------------------------------------------------

LONG=$( awk 'BEGIN { while (i++ < 4096) printf "x" }' )
t_is "$( printf '%s' "${LONG}" | wc -c | tr -d ' ' )" "4096" \
    "the long-value fixture really is four thousand characters"

{
    printf 'notify_cmd=/usr/bin/env MAILRC=/dev/null mail -s seance#1 ops\n'
    printf 'ssh_extra_opts=-o ProxyCommand=ssh -W %%h:%%p bastion\n'
    printf 'names_alpha=%s\n' "${LONG}"
    printf 'names_bravo=caf\303\251-01.example.net\n'
    printf 'names_charlie=back\\slash and \\n not a newline\n'
    printf 'witness=real-witness\n'
    printf 'standby_root=pool/standby witness=hijacked\n'
} > "${DIR}/values.conf"

t_rc 0 "a file of hostile values loads" -- conf_load "${DIR}/values.conf"

t_stdout_is '/usr/bin/env MAILRC=/dev/null mail -s seance#1 ops' \
    "a value keeps every '=' after the first one, and its '#'" -- \
    conf_get notify_cmd

t_stdout_is '-o ProxyCommand=ssh -W %h:%p bastion' \
    "an ssh option string survives verbatim, '=' and '%' and all" -- \
    conf_get ssh_extra_opts

t_is "$( conf_get names_alpha | wc -c | tr -d ' ' )" "4097" \
    "a four-thousand-character value comes back whole (plus its newline)"

t_stdout_is "café-01.example.net" \
    "a non-ASCII value comes back byte for byte" -- conf_get names_bravo

# shellcheck disable=SC2016
#   Single quotes are the point: this is the file's text compared byte for
#   byte, not shell for the test to expand.
t_stdout_is 'back\slash and \n not a newline' \
    "a backslash-n in a value is two characters, not a line break" -- \
    conf_get names_charlie

# The store is one flat string of newline-joined "<key>=<value>" records, so a
# value shaped like a record is the injection that store invites. It cannot
# reach one: read(1) hands over one line at a time, so no value can carry the
# newline a record needs.
t_stdout_is "real-witness" \
    "a value containing \"witness=...\" does not become the witness key" -- \
    conf_get witness

t_stdout_is "pool/standby witness=hijacked" \
    "and the value that contained it is intact" -- conf_get standby_root

t_like "$( conf_dump )" '^names bravo café-01\.example\.net$' \
    "conf_dump prints a non-ASCII value unchanged"

# ---------------------------------------------------------------------------
# Lines that look blank
# ---------------------------------------------------------------------------

{
    printf '   \n'
    printf '\t\t\n'
    printf ' \t \t\n'
    printf 'cadence=900\n'
    printf '\t\n'
    printf '   \t# an indented comment after a whitespace-only line\n'
    printf 'ssh_port=2222\n'
} > "${DIR}/blank.conf"

t_rc 0 "lines made only of spaces and tabs are blank lines, not faults" -- \
    conf_load "${DIR}/blank.conf"
t_stdout_is "900" "a key before them is read" -- conf_get cadence
t_stdout_is "2222" "and a key after them is read" -- conf_get ssh_port

# ---------------------------------------------------------------------------
# A byte-order mark, and other bytes in a key
# ---------------------------------------------------------------------------
#
# An editor that writes a BOM produces a first line that looks exactly right on
# screen. The key is then three bytes longer than it reads, and the only honest
# thing to do is name it -- silently stripping it would teach the file that
# invisible bytes are fine.

printf '\357\273\277cadence=900\nssh_port=22\n' > "${DIR}/bom.conf"
t_rc 2 "a byte-order mark before the first key is a fault, not whitespace" -- \
    conf_load "${DIR}/bom.conf"
t_is "$( errs "${DIR}/bom.conf" )" \
    "$( printf 'bom.conf:1: bad key "\357\273\277cadence": keys are [a-z0-9_]+' )" \
    "the message names line 1 and shows the key it actually got"

printf 'nod\303\250_alpha_mgmt=x\n' > "${DIR}/utf8key.conf"
t_rc 2 "a non-ASCII byte inside a key is a bad key" -- \
    conf_load "${DIR}/utf8key.conf"

f=$( write longkey.conf <<EOF
${LONG}=900
EOF
)
t_rc 2 "a four-thousand-character key is refused" -- conf_load "${f}"
t_like "$( errs "${f}" )" '^longkey\.conf:1: unknown key "xxxx' \
    "and it is refused as an unknown key, not by silently truncating it"

# ---------------------------------------------------------------------------
# Keys that are prefixes of other keys
# ---------------------------------------------------------------------------
#
# The store is searched for "<newline><key>=", and the '=' is the whole of what
# keeps 'node_a_heir' from answering with 'node_a_heir2's value.

f=$( write prefix.conf <<'EOF'
standby_root=fleetwide/standby
node_a_nodename=a.example.net
node_a_mgmt=a-mgmt.example.net
node_a_heir=b
node_a_heir2=c
node_a_standby_root=pernode/standby
node_b_nodename=b.example.net
node_b_mgmt=b-mgmt.example.net
node_b_heir=a
node_c_nodename=c.example.net
node_c_mgmt=c-mgmt.example.net
node_c_heir=a
EOF
)
t_rc 0 "a file whose keys are prefixes of one another loads" -- conf_load "${f}"
t_stdout_is "b" "node_a_heir is not answered by node_a_heir2" -- \
    conf_get node_a_heir
t_stdout_is "fleetwide/standby" \
    "the fleet standby_root is not answered by a node's own" -- \
    conf_get standby_root

# ---------------------------------------------------------------------------
# names_<name>
# ---------------------------------------------------------------------------

f=$( write dupname.conf <<'EOF'
names_alpha=one
names_alpha=two
EOF
)
t_rc 2 "the same display name twice is a duplicate key" -- conf_load "${f}"
t_is "$( errs "${f}" )" 'dupname.conf:2: duplicate key "names_alpha"' \
    "reported at its second appearance, like any other duplicate"

f=$( write upname.conf <<'EOF'
names_Alpha=one
EOF
)
t_rc 2 "a display name that is not [a-z0-9]+ is refused" -- conf_load "${f}"

# ---------------------------------------------------------------------------
# Membership is membership of ONE word
# ---------------------------------------------------------------------------
#
# ' alpha bravo charlie ' contains ' bravo charlie ', so a substring test says
# a two-word heir is a configured node. It is not, and the fleet that config
# validates cleanly would replicate to a node nobody named -- pol_heirs prints
# the two words on one line and every caller word-splits it.

t_rc 0 "a single word is in the list" -- \
    _conf_in_list bravo "alpha bravo charlie"
t_rc 1 "two words of the list are not a member of it" -- \
    _conf_in_list "bravo charlie" "alpha bravo charlie"
t_rc 1 "nor is a word with a tab in it" -- \
    _conf_in_list "$( printf 'bravo\tcharlie' )" "alpha bravo charlie"
t_rc 1 "nor is nothing at all" -- _conf_in_list "" "alpha bravo charlie"

f=$( write twoheirs.conf <<'EOF'
node_alpha_nodename=a.example.net
node_alpha_mgmt=a-mgmt.example.net
node_alpha_heir=bravo charlie
node_bravo_nodename=b.example.net
node_bravo_mgmt=b-mgmt.example.net
node_bravo_heir=alpha
node_charlie_nodename=c.example.net
node_charlie_mgmt=c-mgmt.example.net
node_charlie_heir=alpha
EOF
)
conf_load "${f}" || t_diag "the two-heir file did not load"
t_rc 1 "a heir naming two nodes at once does not validate" -- conf_check
t_like "$( conf_check )" \
    '^problem: node alpha: heir "bravo charlie" is not a configured node$' \
    "and the problem quotes what the operator actually wrote"

# ---------------------------------------------------------------------------
# Forty nodes
# ---------------------------------------------------------------------------

CORPUS="${T_ROOT}/tests/vectors/config/09-forty-nodes.conf"
conf_load "${CORPUS}" || t_diag "the forty-node corpus did not load"

t_stdout_is "40" "the forty-node corpus has forty nodes" -- conf_node_count
t_is "$( conf_nodes | head -1 )/$( conf_nodes | tail -1 )" "n01/n40" \
    "conf_nodes keeps first-appearance order across forty of them"
t_rc 0 "a forty-node succession ring validates" -- conf_check

t_done
