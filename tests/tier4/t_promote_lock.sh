#!/bin/sh
# Tier 4 -- one ladder per corpse, on the MANUAL path (D-155 completed).
#
# D-155 put the detached devd promotion under
# `lockf -s -t 0 <run-dir>/lock/promote.<dead>` and said, in the same entry,
# what it had not done: "a human typing `seance promote` twice is not
# serialised by this". Two ladders for one dead node mount, register and start
# the same estate twice and neither notices the other -- and a human and devd
# reach that in one keystroke, because the operator whose pager just went off
# is exactly the person who types `seance promote` at the node devd is already
# promoting from.
#
# THE CALLER HERE IS AN OPERATOR'S SHELL, BUILT FROM SCRATCH (TESTING.md §0,
# owner's rule of 2026-08-22). `env -i` and then only what the person really
# has: a PATH, a HOME, a TERM, and the SEANCE_CBSD_* facts the module's own
# CBSD verb wrapper exports (D-2). In particular SEANCE_RUN_DIR is NOT set, so
# the lock's location is DERIVED the way a real node derives it --
# ${workdir}/var/run/seance (D-3) -- rather than handed to the code by a test.
#
# WHAT IS FAKED, AND WHAT IS NOT. The lock is real lockf(1), the dispatcher is
# the real bin/seance, the ladder is the real promote_run, the transport is the
# real ssh(1) and the adapter is tests/mock-adapter.subr.
#
# HOW THE WINNER IS MADE TO HOLD THE LOCK FOR AS LONG AS THE TEST NEEDS: with
# the site's own pager. The fleet here is three nodes on the loopback with
# `ssh_port=1`, so the real ssh gets a real refusal in milliseconds and rung 2
# freezes for want of a quorum -- and a rung that freezes NOTIFIES, so
# `notify_cmd` is a script this file wrote, which waits for a file this file
# creates. The ladder is therefore held at a real rung by a real configuration
# key, bounded by seance's own NOTIFY_TIMEOUT if the test dies without
# releasing it.
#
# NOTE, AND IT IS A CONSEQUENCE OF D-171: the shims this file used to put on
# PATH would no longer be reached. bin/seance pins the base system in front of
# the caller's PATH before it runs anything, precisely so that a directory
# ahead of it cannot shadow ssh(1) -- which means a test driving the DISPATCHER
# cannot inject a fake ssh through PATH either. Tier 4's in-process files
# (t_ladder.sh, t_repl_probe.sh) still can, because they source the libraries
# rather than exec the dispatcher; a test at this level uses the real thing and
# arranges the world around it, as this one does.
#
# HOW "EXACTLY ONE LADDER RAN" IS COUNTED: from the mock adapter's own call
# log, not from exit codes. A loser that exits 75 having nonetheless walked
# half a ladder is the failure this file is about, and its exit code would look
# identical (the count-the-resource-not-the-responses rule, TESTING.md §7).
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# The verdict-line grammar the tier-7 oracle holds every invocation to (D-55).
SEANCE_ROOT=${T_ROOT}
export SEANCE_ROOT
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/sim/oracle.subr
. "${T_ROOT}/tests/cluster/sim/oracle.subr"

SEANCE="${T_ROOT}/bin/seance"
WORK=$( t_tmpdir )

t_plan 27

# --- the node ---------------------------------------------------------------
#
# The workdir is where a real node's locks and state come from, and nothing
# below tells seance where they are: it works it out, from the one variable the
# verb wrapper exports.
WORKDIR="${WORK}/workdir"
mkdir -p "${WORKDIR}/jails-system" "${WORKDIR}/jails-data"

GATE="${WORK}/gate.sh"
GO="${WORK}/go"
cat > "${GATE}" <<'EOF'
#!/bin/sh
# The site's pager, which is where a frozen rung ends up -- and which this
# file uses to hold the ladder, and so the lock, until it says otherwise.
set -u
cat > /dev/null
i=0
while [ ! -f "${SEANCE_TEST_GO}" ] && [ "${i}" -lt 250 ]; do
    sleep 0.1
    i=$(( i + 1 ))
done
exit 0
EOF
chmod 0755 "${GATE}"

CONF="${WORK}/seance.conf"
cat > "${CONF}" <<EOF
cadence=900
debounce=0
standby_root=pool0/%n/standby
ssh_port=1
notify_cmd=${GATE}

node_alpha_nodename=alpha
node_alpha_mgmt=127.0.0.1
node_alpha_heir=bravo
node_alpha_heir2=charlie

node_bravo_nodename=bravo
node_bravo_mgmt=127.0.0.2
node_bravo_heir=charlie

node_charlie_nodename=charlie
node_charlie_mgmt=127.0.0.3
node_charlie_heir=bravo
EOF

LOCK="${WORKDIR}/var/run/seance/lock/promote.alpha"
MOCKLOG="${WORK}/mock.log"
: > "${MOCKLOG}"

# operator <args...>  -- the verb as an operator's own shell runs it.
operator()
{
    env -i \
        PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin" \
        HOME=/root LOGNAME=root USER=root TERM=xterm \
        SEANCE_CBSD_WORKDIR="${WORKDIR}" \
        SEANCE_CBSD_NODENAME=bravo \
        SEANCE_CONF="${CONF}" \
        SEANCE_ADAPTER="${T_ROOT}/tests/mock-adapter.subr" \
        SEANCE_ROOT="${T_ROOT}" \
        SEANCE_MOCK_NODE=bravo \
        SEANCE_MOCK_WORKDIR="${WORKDIR}" \
        SEANCE_MOCK_LOG="${MOCKLOG}" \
        SEANCE_TEST_GO="${GO}" \
        "${SEANCE}" "$@"
}

# ladders_run  -- how many promotions actually started, counted from the
# adapter's log rather than from anybody's exit code.
ladders_run()
{
    awk '$1 == "adapter_init" { n++ } END { print n + 0 }' "${MOCKLOG}"
}

# lock_free  -- rc 0 when the lock can be taken right now. This is the only
# honest question to ask about a lockf(1) lock: the file's existence answers
# nothing (lockf(1): "the mere existence of the file is not considered to
# constitute a lock").
lock_free()
{
    [ -e "${LOCK}" ] || return 0
    lockf -s -t 0 "${LOCK}" true < /dev/null
}

# wait_locked  -- wait until something really holds the lock, or give up.
wait_locked()
{
    local _i

    _i=0
    while [ "${_i}" -lt 100 ]; do
        lock_free || return 0
        sleep 0.1
        _i=$(( _i + 1 ))
    done

    return 1
}

# ---------------------------------------------------------------------------
# A holder that is not seance, so that the refusal can be measured on its own
# ---------------------------------------------------------------------------

mkdir -p "${WORKDIR}/var/run/seance/lock"
lockf -s -t 0 -p "${LOCK}" sleep 60 < /dev/null > /dev/null 2>&1 &
HOLDER=$!
t_at_exit "kill -9 ${HOLDER} 2>/dev/null"

if wait_locked; then
    t_ok "the fixture holder has the corpse's lock"
else
    t_not_ok "the fixture holder has the corpse's lock"
    t_done
fi

HELD_PID=$( cat "${LOCK}" 2>/dev/null )

OUT="${WORK}/loser.out"
operator promote alpha > "${OUT}" 2>&1
RC=$?

t_is "${RC}" "75" "a promotion of a node this host is already promoting exits 75 (EX_TEMPFAIL)"
t_like "$( cat "${OUT}" )" "another promotion of alpha is running on this node and holds ${LOCK}" \
    "and says what stopped it, naming the corpse and the lock"
t_like "$( cat "${OUT}" )" "The holder is pid ${HELD_PID}:" \
    "and names WHO holds it, from the pid lockf(1) -p recorded"
t_like "$( cat "${OUT}" )" 'not a stale lock file' \
    "and says why the refusal is evidence of a live holder rather than of a leftover file"
t_like "$( cat "${OUT}" )" 'per node and per dead node' \
    "and states the narrowing: another NODE promoting the same corpse is not visible from here"
t_like "$( awk 'NF > 0 { line = $0 } END { print line }' "${OUT}" )" \
    '^promote: NOTHING WAS PROMOTED: this node already has a ladder running for alpha$' \
    "and the LAST line is the verdict, which is what a reader and an oracle both take (D-110)"
if printf '%s\n' "$( awk 'NF > 0 { line = $0 } END { print line }' "${OUT}" )" |
       grep -Eq "${ORACLE_VERDICT_RE}"; then
    t_ok "the verdict line is one the tier-7 oracle accepts"
else
    t_not_ok "the verdict line is one the tier-7 oracle accepts"
fi
t_is "$( ladders_run )" "0" \
    "and NO ladder ran: the loser did not reach the adapter, let alone the estate"

# --force is not a licence to race ------------------------------------------
operator promote alpha --force > "${WORK}/force.out" 2>&1
t_is "$?" "75" "--force does not bypass the lock: a force accepts a rung, not a second ladder"
operator promote alpha --force=fence --guest web01 > "${WORK}/force2.out" 2>&1
t_is "$?" "75" "and neither does a force naming one rung and one guest"
t_is "$( ladders_run )" "0" "still no ladder: three refusals, nothing walked"

# --locked is the caller saying it holds the lock already ---------------------
#
# It is what the devd path passes inside its own lockf(1) wrapper. Without it
# that child would take the same lock a second time, flock(2) would refuse it,
# and every automatic promotion would exit 75 having done nothing.
: > "${GO}"
operator promote alpha --locked > "${WORK}/locked.out" 2>&1
LOCKED_RC=$?
t_isnt "${LOCKED_RC}" "75" \
    "--locked runs the ladder while the lock is held, because its caller is the holder"
t_like "$( cat "${WORK}/locked.out" )" '^rung ' \
    "and it really walked rungs rather than returning early"
t_is "$( ladders_run )" "1" "exactly one ladder ran"
rm -f "${GO}"

# ---------------------------------------------------------------------------
# The holder dies. The FILE is not the lock.
# ---------------------------------------------------------------------------

# Both halves: lockf(1) is the holder, and the sleep(1) it is holding the lock
# for is its own child. Killing only the wrapper would leave the child running
# for the rest of its minute, attached to this script's own stdout.
kill -9 "${HOLDER}" "${HELD_PID}" 2>/dev/null
wait "${HOLDER}" 2>/dev/null

t_rc 0 "a holder killed with SIGKILL leaves its lock FILE behind" -- test -e "${LOCK}"
t_rc 0 "and the lock itself is gone with it, because lockf(1) locks with flock(2)" \
    -- lock_free

: > "${MOCKLOG}"
: > "${GO}"
operator promote alpha > "${WORK}/after.out" 2>&1
AFTER_RC=$?
t_isnt "${AFTER_RC}" "75" \
    "so the next promotion takes the lock rather than reading the leftover file as a holder"
t_is "$( ladders_run )" "1" "and that one really did walk the ladder"
rm -f "${GO}"

# ---------------------------------------------------------------------------
# THE ROW THIS FILE EXISTS FOR: two real promotions, one corpse, one node
# ---------------------------------------------------------------------------

: > "${MOCKLOG}"
rm -f "${GO}"

operator promote alpha > "${WORK}/race1.out" 2>&1 &
RACE1=$!
t_at_exit "kill -9 ${RACE1} 2>/dev/null"

if wait_locked; then
    t_ok "the first promotion has taken the corpse's lock"
else
    t_not_ok "the first promotion has taken the corpse's lock"
fi

operator promote alpha > "${WORK}/race2.out" 2>&1
RACE2_RC=$?

t_is "${RACE2_RC}" "75" "the second promotion of the same corpse exits 75"
t_like "$( cat "${WORK}/race2.out" )" \
    'The holder is pid [0-9]+: .*bin/seance promote alpha --locked' \
    "and names the first one's own re-entered dispatcher as the holder"

: > "${GO}"
wait "${RACE1}"
RACE1_RC=$?

t_isnt "${RACE1_RC}" "75" "the first one was not refused anything"
t_is "$( ladders_run )" "1" \
    "and ONE ladder ran for the two commands -- counted from the adapter, not from exit codes"

t_rc 1 "the lock is released when the promotion ends, file and all" -- test -e "${LOCK}"

# A SECOND CORPSE IS A SECOND ESTATE, and is not held by the first one's lock.
# The lock is named after the dead node for exactly this reason (D-155).
: > "${MOCKLOG}"
rm -f "${GO}"

operator promote alpha > "${WORK}/two1.out" 2>&1 &
TWO1=$!
t_at_exit "kill -9 ${TWO1} 2>/dev/null"
wait_locked || t_diag "the alpha promotion did not take its lock in time"

: > "${GO}"
operator promote charlie > "${WORK}/two2.out" 2>&1
TWO2_RC=$?
wait "${TWO1}" 2>/dev/null

t_isnt "${TWO2_RC}" "75" \
    "promoting a DIFFERENT dead node is not blocked by the first one's ladder"
t_is "$( ladders_run )" "2" "and both ladders ran"

t_done
