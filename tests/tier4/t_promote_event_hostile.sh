#!/bin/sh
# Tier 4 -- `promote-event` under hostile input, and under a devd(8) that
# delivers the same transition twice.
#
# `tests/tier4/t_promote_event.sh` covers the verb's happy path and the one
# property devd(8) makes non-negotiable (it returns at once). This file is the
# other half: what arrives at a devd action is a string somebody else composed,
# and what devd does with a flapping link is deliver the transition again.
#
# Three things are asserted, and each is about a way a wrong answer is worse
# than a refusal:
#
#   * AN IMPOSSIBLE VHID IS A CONTRACT ERROR, not somebody else's cluster.
#     carp(4) and ifconfig(8) pin the range at 1..255 and lib/conf.subr
#     enforces it on every node block (CONF_VHID_MIN..CONF_VHID_MAX), so 0,
#     256 and 999 cannot come from the kernel. Read as "a vhid this fleet does
#     not claim" they exit 0 with a line saying nothing is wrong -- which is
#     the answer a MISROUTED RULE gets, and the same shape of answer a real
#     foreign vhid gets. D-99 resolved exactly this asymmetry inside the
#     adapter; this is the same question at the entry point.
#
#   * AN IFNAME IS A NAME. Everything after the '@' is devd's own if_name()
#     (sbin/devd/devd.cc writes "%u@%s"), which is [A-Za-z0-9._] and nothing
#     else. A subsystem carrying a ';', a '$(' or a second '@' is not a CARP
#     event, and the verb that runs as root out of a devd action refuses it
#     rather than interpolating it into a message and acting on the rest.
#
#   * TWO EVENTS FOR ONE VHID RUN ONE LADDER. A link that flaps makes devd
#     deliver MASTER, BACKUP and MASTER again inside `debounce`, and each
#     MASTER detaches a promotion of the same corpse. Two ladders on one node
#     fence the same host twice, walk the same estate twice and write the same
#     succession twice. Counted here from STATE -- how many ladders actually
#     started -- and never from exit codes, because both detaches succeed.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SEANCE_ROOT=${T_ROOT}
export SEANCE_ROOT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/common.subr
. "${T_ROOT}/lib/common.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/policy.subr
. "${T_ROOT}/lib/policy.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/conf.subr
. "${T_ROOT}/lib/conf.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/transport.subr
. "${T_ROOT}/lib/transport.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/notify.subr
. "${T_ROOT}/lib/notify.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/zfs.subr
. "${T_ROOT}/lib/zfs.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/lineage.subr
. "${T_ROOT}/lib/lineage.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/repl.subr
. "${T_ROOT}/lib/repl.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/status.subr
. "${T_ROOT}/lib/status.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/carp.subr
. "${T_ROOT}/lib/carp.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/gate.subr
. "${T_ROOT}/lib/gate.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/promote.subr
. "${T_ROOT}/lib/promote.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../mock-adapter.subr
. "${T_ROOT}/tests/mock-adapter.subr"

SEANCE_TMP_REGISTRY=$( t_tmpdir )/registry
: > "${SEANCE_TMP_REGISTRY}"
export SEANCE_TMP_REGISTRY
t_at_exit 'seance_tmp_cleanup'

NOTIFY_TIMEOUT=2

WORK=$( t_tmpdir )
SHIM="${WORK}/bin"
mkdir -p "${SHIM}"

# The run directory is where the locks live (D-3). A test that let it default
# would be a test of whatever CBSD workdir happened to be exported.
SEANCE_RUN_DIR="${WORK}/run"
export SEANCE_RUN_DIR

# daemon(8), as far as this verb is concerned: it consumes its own options and
# then starts the command, which OUTLIVES it. Everything after the options is
# run for real -- including the lockf(1) the fix puts in front of the verb --
# so what is counted below is what a node would actually have started.
cat > "${SHIM}/daemon" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${WORLD_DIR}/daemon.log"
while [ $# -gt 0 ]; do
    case "$1" in
        -f) shift ;;
        -S) shift ;;
        -T|-l|-s|-p|-P|-u|-o) shift 2 ;;
        *) break ;;
    esac
done
[ $# -gt 0 ] || exit 1
"$@" < /dev/null >> "${WORLD_DIR}/detached.log" 2>&1 &
exit 0
EOF

# The platform's own verb. A ladder that has started says so, and then takes
# long enough that a second event arriving in the same breath meets it running.
cat > "${SHIM}/pretend-platform" <<'EOF'
#!/bin/sh
set -u
printf 'ladder: %s\n' "$*" >> "${WORLD_DIR}/ladders.log"
sleep 3
exit 0
EOF

cat > "${SHIM}/logger" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${WORLD_DIR}/logger.log"
exit 0
EOF

chmod 0755 "${SHIM}/daemon" "${SHIM}/pretend-platform" "${SHIM}/logger"
PATH="${SHIM}:${PATH}"
export PATH

WORLD_DIR=${WORK}
export WORLD_DIR

SEANCE_MOCK_NODE=bravo
SEANCE_MOCK_WORKDIR="${WORK}/workdir"
SEANCE_MOCK_LOG="${WORK}/mock.log"
SEANCE_MOCK_SCRIPT="${WORK}/mock.script"
SEANCE_MOCK_VERB="${SHIM}/pretend-platform seance"
export SEANCE_MOCK_NODE SEANCE_MOCK_WORKDIR SEANCE_MOCK_LOG SEANCE_MOCK_SCRIPT
export SEANCE_MOCK_VERB
mkdir -p "${SEANCE_MOCK_WORKDIR}"
: > "${SEANCE_MOCK_SCRIPT}"

# conf <auto> <armed>  -- the three-node ring of t_promote_event.sh, so that
# the two files describe one fleet and a difference between them is a
# difference in what is being asserted.
conf()
{
    local _f

    _f="${WORK}/seance.conf"
    {
        printf 'carp_interface=vtnet0\n'
        printf 'auto=%s\n' "$1"
        printf 'node_alpha_nodename=alpha\n'
        printf 'node_alpha_mgmt=alpha-mgmt.example.net\n'
        printf 'node_alpha_heir=bravo\n'
        printf 'node_alpha_heir2=charlie\n'
        printf 'node_alpha_vhid=1\n'
        printf 'node_alpha_vhid_ip=192.0.2.101/32\n'
        printf 'node_bravo_nodename=bravo\n'
        printf 'node_bravo_mgmt=bravo-mgmt.example.net\n'
        printf 'node_bravo_heir=charlie\n'
        printf 'node_bravo_heir2=alpha\n'
        printf 'node_bravo_vhid=2\n'
        printf 'node_bravo_vhid_ip=192.0.2.102/32\n'
        [ -n "$2" ] && printf 'node_bravo_auto_promote=%s\n' "$2"
        printf 'node_charlie_nodename=charlie\n'
        printf 'node_charlie_mgmt=charlie-mgmt.example.net\n'
        printf 'node_charlie_heir=alpha\n'
        printf 'node_charlie_heir2=bravo\n'
        printf 'node_charlie_vhid=3\n'
        printf 'node_charlie_vhid_ip=192.0.2.103/32\n'
    } > "${_f}"

    conf_load "${_f}"
}

# reset_world  -- empty every record the assertions count from.
reset_world()
{
    : > "${WORK}/daemon.log"
    : > "${WORK}/logger.log"
    : > "${WORK}/ladders.log"
    : > "${WORK}/detached.log"
    rm -rf "${SEANCE_RUN_DIR}"
}

RUN_OUT=""
RUN_RC=0
RUN_SECS=0
run()
{
    local _t0 _t1

    _t0=$( date -u +%s )
    RUN_OUT=$( promote_event "$1" 2>&1 )
    RUN_RC=$?
    _t1=$( date -u +%s )
    RUN_SECS=$(( _t1 - _t0 ))
}

# ladders  -- how many promotions actually started. THE COUNT IS THE ASSERTION:
# both detaches exit 0 whatever happens after them, so an exit code cannot tell
# one ladder from two.
ladders()
{
    awk 'END { print NR + 0 }' "${WORK}/ladders.log"
}

t_plan 30

conf 1 "alpha charlie" || t_diag "the configuration failed to load"

# ---------------------------------------------------------------------------
# An impossible vhid is a contract error
# ---------------------------------------------------------------------------

for v in 0 256 999; do
    reset_world
    run "${v}@vtnet0"
    t_is "${RUN_RC}" "2" \
        "vhid ${v} is not a CARP vhid, and promote-event refuses it (rc 2)"
    t_is "$( cat "${WORK}/daemon.log" )" "" \
        "and vhid ${v} detached nothing"
done

reset_world
run "0@vtnet0"
t_like "${RUN_OUT}" "1\.\.255" \
    "the refusal names the range, so an operator testing a rule by hand can see why"

# A vhid spelled with a leading zero is a vhid that matches no node block, so
# reading it as "not ours" would answer a real death with silence.
reset_world
run "01@vtnet0"
t_is "${RUN_RC}" "2" \
    "a vhid spelled with a leading zero is refused, not read as a foreign cluster"
t_is "$( cat "${WORK}/daemon.log" )" "" \
    "and it detached nothing"

# The one that must NOT be refused, kept beside them: a vhid inside the range
# that this configuration does not claim is another cluster on the segment.
reset_world
run "255@vtnet0"
t_is "${RUN_RC}" "0" \
    "a vhid inside the range that no node claims is still not an error"
t_like "${RUN_OUT}" 'belongs to no node in this configuration' \
    "and is still named as somebody else's"
t_is "$( cat "${WORK}/logger.log" )" "" \
    "and pages nobody: a shared segment must not turn every foreign transition into a notification"

# ---------------------------------------------------------------------------
# An ifname is a name
# ---------------------------------------------------------------------------

reset_world
run "1@vtnet0@vtnet1"
t_is "${RUN_RC}" "2" \
    "a subsystem with two '@' is not devd's <vhid>@<ifname>"

reset_world
run "1@vtnet0; touch ${WORK}/pwned"
t_is "${RUN_RC}" "2" \
    "an ifname carrying a shell separator is refused"
t_rc 1 "and nothing ran it: the file it asked for does not exist" \
    -- test -e "${WORK}/pwned"

reset_world
# shellcheck disable=SC2016
#   The single quotes are the point: the command substitution is source text
#   being handed to the verb as an argument, not an expansion for this shell.
run '1@$( id -u > '"${WORK}"'/pwned2 )'
t_is "${RUN_RC}" "2" \
    "an ifname carrying a command substitution is refused"
t_rc 1 "and nothing expanded it either" -- test -e "${WORK}/pwned2"

reset_world
run "1@vtnet0
1@vtnet0"
t_is "${RUN_RC}" "2" \
    "and an ifname carrying a newline is refused rather than read as two events"

# The two halves of the ifname contract have a row each that only they can
# satisfy: the long injections above are ALSO longer than an interface name
# can be, so without these two a mutation could take either check away and
# leave the other covering for it.
reset_world
run "1@a;b"
t_is "${RUN_RC}" "2" \
    "a short ifname with a separator in it is refused by the charset, not by the length"

reset_world
run "1@abcdefghijklmnopq"
t_is "${RUN_RC}" "2" \
    "and a legal-looking name longer than IFNAMSIZ-1 is refused by the length"

# The interface that is merely the WRONG one is information, not permission
# (the rendering may be out of date): it still acts, and says so.
reset_world
run "1@em9"
t_is "${RUN_RC}" "0" \
    "an event on an interface that is not this node's carp_interface still acts"
t_like "$( cat "${WORK}/daemon.log" )" 'promote alpha --auto' \
    "and detaches the promotion of the node the vhid stands for"

# ---------------------------------------------------------------------------
# Two events for one vhid run ONE ladder
# ---------------------------------------------------------------------------

reset_world
run "1@vtnet0"
FIRST_RC=${RUN_RC}
run "1@vtnet0"
SECOND_SECS=${RUN_SECS}
SECOND_RC=${RUN_RC}
sleep 5

t_is "${FIRST_RC}${SECOND_RC}" "00" \
    "both events exit 0: devd is told nothing is wrong, because nothing is"
t_is "$( ladders )" "1" \
    "two MASTER events for one vhid inside debounce start exactly ONE ladder"
t_rc 0 "and the second event still returns at once, so devd's loop is not held" \
    -- test "${SECOND_SECS}" -lt "${PROMOTE_EVENT_DETACH_TIMEOUT}"

# A second corpse is a second estate, and must not be held by the first one's
# ladder: the exclusion is per dead node, not per node.
run "3@vtnet0"
sleep 5
t_is "$( ladders )" "2" \
    "an event for a DIFFERENT corpse starts its own ladder: the exclusion is per corpse"
t_like "$( cat "${WORK}/ladders.log" )" 'promote charlie --auto' \
    "and it is charlie's ladder, not a second run at alpha"

# And it is an exclusion, not a gate: once the ladder is gone the next death is
# still answered. A lock that outlived its holder would silence the second one.
sleep 1
run "1@vtnet0"
sleep 5
t_is "$( ladders )" "3" \
    "once the first ladder has finished, a later event for the same corpse starts one again"

# ---------------------------------------------------------------------------
# A flood at an unarmed node
# ---------------------------------------------------------------------------

conf 1 "" || t_diag "the unarmed-node configuration failed to load"
reset_world
run "1@vtnet0"
run "1@vtnet0"
run "1@vtnet0"
sleep 1
t_is "$( ladders )" "0" \
    "three events at a node that is not armed start no ladder at all"
# The notifications are sent by a child this verb does not wait for (devd waits
# for the verb, so the verb waits for nobody's script), so the count is taken
# after giving those children a moment. Without the wait this row would be a
# race that usually passes, which is worse than one that usually fails.
sleep 2

# Counted on the syslog line the NOTIFICATION itself writes (logger's
# "-- <subject>"), not on every line mentioning the subject: seance_log echoes
# it once more as "NOTIFY: <subject>", and a count that included both would
# pass just as happily if the notification had been sent twice or not at all.
t_is "$( grep -c -- '-- CARP MASTER for alpha observed, automation not armed$' \
    "${WORK}/logger.log" )" "3" \
    "and each of them notified: an unarmed node's silence would be the failure"

t_done
