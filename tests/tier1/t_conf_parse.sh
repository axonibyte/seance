#!/bin/sh
# Tier 1 -- the config grammar, and what it does with hostile input.
#
# The config file is parsed and never sourced (handoff §2.2). That decision is
# only worth anything if the parser is actually strict, so this file feeds it
# the things a real seance.conf will eventually be fed by accident: a line with
# no '=', a key with a capital in it, the same key twice, a file saved by an
# editor that writes CRLF, a '#' in the middle of a value, a key that is one
# letter away from a real one.
#
# Two behaviours are load-bearing and are asserted rather than assumed. Every
# fault is reported, not just the first, because a check that reports one typo
# per round trip is a check that gets skipped. And an unknown key stops the
# load, because a mistyped key is not a setting seance ignores -- it is a
# setting the operator believes is in force and is not.
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

t_plan 55

# --- what parses -----------------------------------------------------------

f=$( write ok.conf <<'EOF'
# a comment
    # an indented comment

cadence=900
    ssh_port=2222
ssh_user=admin
EOF
)
t_rc 0 "a well-formed file loads" -- conf_load "${f}"
t_stdout_is "900" "a plain key" -- conf_get cadence
t_stdout_is "2222" "an indented key is still a key" -- conf_get ssh_port
t_stdout_is "admin" "a value is taken verbatim" -- conf_get ssh_user
t_rc 1 "a key the file did not set is unset" -- conf_get witness
t_stdout_is "fallback" "conf_get returns the default it is given" -- \
    conf_get witness fallback
t_rc 0 "conf_has finds a key that was set" -- conf_has cadence
t_rc 1 "conf_has does not find one that was not" -- conf_has witness

# --- whitespace and '#' ----------------------------------------------------

# Written with printf rather than a here-document: the whitespace this block
# is about is trailing, and trailing whitespace in a here-document is invisible
# in review and is eaten by the first editor that touches the file. Written as
# escapes it is legible, and it stays.
{
    printf 'cadence=900   \n'
    printf 'ssh_port=22\t\t\n'
    printf 'ssh_user=\tadmin \t\n'
    printf 'notify_cmd=/usr/bin/mail -s seance # and a hash\n'
    printf 'witness=\n'
} > "${DIR}/ws.conf"
f="${DIR}/ws.conf"

t_rc 0 "trailing whitespace and inline hashes load" -- conf_load "${f}"
t_stdout_is "900" "trailing spaces are trimmed from a value" -- \
    conf_get cadence
t_stdout_is "22" "trailing tabs are trimmed too" -- conf_get ssh_port
t_stdout_is "	admin" "leading whitespace in a value is kept, trailing is not" -- \
    conf_get ssh_user
t_stdout_is "/usr/bin/mail -s seance # and a hash" \
    "a '#' after a value is part of the value" -- conf_get notify_cmd
t_rc 0 "a key set to nothing is still set" -- conf_has witness
t_stdout_is "" "a key set to nothing has an empty value" -- conf_get witness

# --- what does not parse ---------------------------------------------------

f=$( write nokv.conf <<'EOF'
cadence 900
EOF
)
t_rc 2 "a line with no '=' is an error" -- conf_load "${f}"
t_is "$( errs "${f}" )" "nokv.conf:1: not a comment and not key=value" \
    "the error names the file and the line"

f=$( write badkey.conf <<'EOF'
Cadence=900
EOF
)
t_rc 2 "an uppercase key is an error" -- conf_load "${f}"
t_like "$( errs "${f}" )" '^badkey\.conf:1: bad key "Cadence"' \
    "the error names the key"

f=$( write dashkey.conf <<'EOF'
ssh-port=22
EOF
)
t_rc 2 "a dash in a key is an error" -- conf_load "${f}"
t_like "$( errs "${f}" )" '^dashkey\.conf:1: bad key "ssh-port"' \
    "a dashed key is reported as a bad key, not an unknown one"

f=$( write emptykey.conf <<'EOF'
=900
EOF
)
t_rc 2 "an empty key is an error" -- conf_load "${f}"
t_like "$( errs "${f}" )" '^emptykey\.conf:1: bad key ""' \
    "an empty key is reported"

f=$( write dup.conf <<'EOF'
cadence=900
cadence=300
EOF
)
t_rc 2 "a duplicate key is an error" -- conf_load "${f}"
t_is "$( errs "${f}" )" 'dup.conf:2: duplicate key "cadence"' \
    "the duplicate is reported at its second appearance"

f=$( write unknown.conf <<'EOF'
node_alpha_mgnt=alpha-mgmt.example.net
EOF
)
t_rc 2 "a key one letter away from a real one is an error" -- conf_load "${f}"
t_is "$( errs "${f}" )" \
    'unknown.conf:1: unknown key "node_alpha_mgnt"' \
    "the typo the check exists to catch is caught"

f=$( write unknownfleet.conf <<'EOF'
cadance=900
EOF
)
t_rc 2 "an unknown fleet key is an error" -- conf_load "${f}"
t_like "$( errs "${f}" )" '^unknownfleet\.conf:1: unknown key "cadance"' \
    "an unknown fleet key is named"

f=$( write badguest.conf <<'EOF'
guest_db01_home=alpha
EOF
)
t_rc 2 "a guest key outside the allowed four is an error" -- conf_load "${f}"
t_like "$( errs "${f}" )" '^badguest\.conf:1: unknown key "guest_db01_home"' \
    "guest overrides are restricted to the documented keys"

f=$( write badname.conf <<'EOF'
node_alpha-one_mgmt=x
EOF
)
t_rc 2 "a node name with a dash in a key is an error" -- conf_load "${f}"

f=$( write shortnode.conf <<'EOF'
node_alpha=x
EOF
)
t_rc 2 "node_<name> with no field is an error" -- conf_load "${f}"

# --- CRLF ------------------------------------------------------------------
#
# A carriage return is refused outright rather than trimmed as whitespace. A
# trimmed CR would let a file edited on another platform load and then fail
# somewhere far away with a baffling message about an integer that looks
# perfectly fine on screen; refusing it names the real problem at the line it
# is on.

printf 'cadence=900\r\nssh_port=22\r\n' > "${DIR}/crlf.conf"
t_rc 2 "a CRLF file is an error" -- conf_load "${DIR}/crlf.conf"
t_is "$( errs "${DIR}/crlf.conf" )" \
    "crlf.conf:1: carriage return in line (CRLF line endings are not supported)
crlf.conf:2: carriage return in line (CRLF line endings are not supported)" \
    "every CRLF line is reported, with its number"

printf 'cadence=900\rssh_port=22\n' > "${DIR}/embedcr.conf"
t_rc 2 "a bare CR inside a line is an error too" -- \
    conf_load "${DIR}/embedcr.conf"

# --- every fault is reported ----------------------------------------------

f=$( write many.conf <<'EOF'
cadence=900
nokeyvalue
Cadence=1
cadance=2
cadence=300
EOF
)
t_rc 2 "a file with four faults is an error" -- conf_load "${f}"
t_is "$( errs "${f}" )" 'many.conf:2: not a comment and not key=value
many.conf:3: bad key "Cadence": keys are [a-z0-9_]+
many.conf:4: unknown key "cadance"
many.conf:5: duplicate key "cadence"' "all four faults are reported, in order"

# --- odd but legal files ---------------------------------------------------

printf '' > "${DIR}/empty.conf"
t_rc 0 "an empty file parses" -- conf_load "${DIR}/empty.conf"
t_stdout_is "0" "an empty file has no nodes" -- conf_node_count

printf '# only a comment\n' > "${DIR}/comments.conf"
t_rc 0 "a file of nothing but comments parses" -- conf_load "${DIR}/comments.conf"

printf 'cadence=900' > "${DIR}/nonl.conf"
t_rc 0 "a last line with no newline parses" -- conf_load "${DIR}/nonl.conf"
t_stdout_is "900" "and its value is read" -- conf_get cadence

t_rc 2 "an unreadable file is a contract error" -- conf_load "${DIR}/absent.conf"
t_rc 2 "no file at all is a contract error" -- conf_load
t_rc 2 "an empty path is a contract error" -- conf_load ""

# --- values are text, never code ------------------------------------------
#
# The reason this file is parsed and not sourced. Whatever is on the right of
# the '=' comes back out byte for byte: no expansion, no substitution, no
# execution, and no amount of shell metacharacter gets a word in.

f=$( write hostile.conf <<'EOF'
notify_cmd=$( touch /tmp/seance-parser-was-sourced ); echo ${HOME} `id`
EOF
)
t_rc 0 "a value full of shell metacharacters loads" -- conf_load "${f}"
# shellcheck disable=SC2016
#   The single quotes are the point: this string is the config file's text
#   being compared byte for byte, not shell for the test to expand.
t_stdout_is '$( touch /tmp/seance-parser-was-sourced ); echo ${HOME} `id`' \
    "a value is returned verbatim, unexpanded and unexecuted" -- \
    conf_get notify_cmd
t_rc 1 "and nothing in it ran" -- test -e /tmp/seance-parser-was-sourced

# --- loading twice forgets the first file ---------------------------------

f=$( write first.conf <<'EOF'
cadence=600
node_alpha_nodename=a
node_alpha_mgmt=m
EOF
)
g=$( write second.conf <<'EOF'
ssh_port=2222
EOF
)
conf_load "${f}" || t_diag "first load failed"
conf_load "${g}" || t_diag "second load failed"
t_rc 1 "a reload forgets the previous file's keys" -- conf_has cadence
t_stdout_is "0" "a reload forgets the previous file's nodes" -- conf_node_count
t_stdout_is "2222" "and keeps its own" -- conf_get ssh_port

# --- a failed load leaves nothing behind ----------------------------------

conf_load "${f}" || t_diag "first load failed"
# Called directly rather than through errs(), which pipes and so would run the
# load in a subshell whose effect on the loaded state the parent never sees.
# The diagnostics go to a file and are asserted, not discarded.
conf_load "${DIR}/many.conf" 2> "${DIR}/many.err"
t_isnt "$( cat "${DIR}/many.err" )" "" "the failing reload did report its faults"
t_rc 1 "a failed load does not leave the previous file loaded" -- \
    conf_has cadence
t_stdout_is "0" "and does not leave its own partial contents either" -- \
    conf_node_count

t_done
