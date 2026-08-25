#!/bin/sh
# Tier 6, stage 'replfail' -- one heir lost in the middle of a tick.
#
# The `repl` stage proves a tick that works and a pair that was already
# unreachable when it started. This stage proves the case in between, which is
# the one a real fleet meets: three nodes, a tick under way, and one heir's
# network goes at the moment its stream is in flight.
#
# What must hold afterwards, and why each one matters:
#
#   * the OTHER pair still completes. A tick is not a transaction; a peer that
#     dies must cost its own pair and nothing else, or one flaky heir stops
#     every guest from being replicated anywhere.
#   * the tick's verdict and exit code report the failure. A tick that lost a
#     replica and exited 0 is the quiet failure this project exists to stop.
#   * the failed pair's lag record MOVES ON and KEEPS the timestamp the peer was
#     last known to hold. Both halves: if the record does not move, `status`
#     goes on reporting the last good tick and exits 0 while replication is
#     broken; if it forgets the timestamp, the fleet loses the one number that
#     says how much data a promotion onto that peer would cost, and the
#     staleness clock that would eventually escalate stops running.
#   * the source keeps everything. A failed send may not destroy a snapshot on
#     the sending side -- the lineage in evidence is worth more than the disk.
#   * after the heal, the next tick puts the pair back, resuming the stream the
#     cut interrupted rather than starting again.
#
# The cut is made mid-stream on purpose, and deterministically. Charlie's
# replica is destroyed first, so charlie's pair owes a FULL send of a payload
# large enough to take seconds. The stage then waits for CHARLIE'S OWN replica
# child dataset to appear on charlie -- the receive creates it as the bulk
# stream begins -- and only then cuts the bridge. Waiting for bravo's snapshot
# instead is not enough and was tried first: it fires while bravo's own bulk
# send is still running and charlie's pair has not started, which is the
# already-unreachable case the `repl` stage covers, wearing this stage's name.
# The evidence that the window was hit is asserted (a partially received
# dataset with a receive_resume_token), not assumed.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/stage.subr
. "${T_ROOT}/tests/cluster/lib/stage.subr"

stage_begin replfail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the replfail stage builds jails and ZFS datasets; it needs root"
    echo "t_replfail: must run as root" >&2
    exit 2
fi

t_plan 31

TAB=$( printf '\t.' )
TAB=${TAB%.}

SN_ADAPTER="/usr/local/seance/tests/cluster/adapter-pseudo.subr"
SN_ENV="SEANCE_CONF=/etc/seance.conf SEANCE_STATE_DIR=/var/db/seance SEANCE_RUN_DIR=/var/run/seance SEANCE_ADAPTER=${SN_ADAPTER}"
SN_BIN="/usr/local/seance/bin/seance"

# node_seance <node> <args...> -- a seance verb inside a node.
#
# shellcheck disable=SC2329
#   Invoked indirectly by t_rc, which runs the command after its '--'.
node_seance()
{
    local _n

    _n=$1
    shift

    # shellcheck disable=SC2086
    #   Deliberate word splitting: ${SN_ENV} is a list of VAR=value words for
    #   env(1), each of which must arrive as its own argument.
    cluster_exec "${_n}" env ${SN_ENV} "${SN_BIN}" "$@" < /dev/null
}

node_sh()
{
    local _n

    _n=$1
    shift

    # shellcheck disable=SC2086
    #   Deliberate word splitting, as above.
    cluster_exec "${_n}" env ${SN_ENV} sh -c "$*" < /dev/null
}

nz()
{
    local _n

    _n=$1
    shift

    cluster_exec "${_n}" zfs "$@" < /dev/null
}

# snaps <node> <dataset> -- the short names under a dataset tree, sorted.
snaps()
{
    nz "$1" list -H -o name -t snapshot -r "$2" 2>/dev/null |
        sed 's/.*@//' | LC_ALL=C sort -u
}

# newest_ours <node> <dataset> -- the newest seance-alpha-* short name there.
newest_ours()
{
    snaps "$1" "$2" | grep '^seance-alpha-' | LC_ALL=C sort | tail -1
}

# lag <node> <guest> <peer> -- the pair's lag record, or the empty string.
lag()
{
    cluster_exec "$1" cat "/var/db/seance/lag/$2.$3" < /dev/null 2>/dev/null
}

# ---------------------------------------------------------------------------
# The cluster
# ---------------------------------------------------------------------------

cluster_up 3 || { t_diag "cluster_up failed"; t_done; }

BASE_DS=$( cluster_base_dataset )
ALPHA_DS=$( cluster_dataset alpha )

CONF=$( t_tmpdir )/seance.conf
cat > "${CONF}" <<EOF
cadence=60
retention_recent=14400
retention_hourly=172800
skew_tolerance=120
ssh_user=root
ssh_port=22
ssh_extra_opts=-i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
standby_root=${BASE_DS}/%n/standby

node_alpha_nodename=alpha
node_alpha_mgmt=$( cluster_ip alpha )
node_alpha_heir=bravo
node_alpha_heir2=charlie

node_bravo_nodename=bravo
node_bravo_mgmt=$( cluster_ip bravo )
node_bravo_heir=charlie
node_bravo_heir2=alpha

node_charlie_nodename=charlie
node_charlie_mgmt=$( cluster_ip charlie )
node_charlie_heir=alpha
node_charlie_heir2=bravo
EOF

for n in alpha bravo charlie; do
    cp "${CONF}" "$( cluster_root "${n}" )/etc/seance.conf"
done

node_sh alpha ". ${SN_ADAPTER}; adapter_init && pseudo_guest_create web01 jail alpha" ||
    t_diag "creating web01 failed"
nz alpha create "${ALPHA_DS}/web01/data" || t_diag "web01's child dataset"
cluster_exec alpha sh -c 'echo v1 > /seance/web01/data/marker' < /dev/null

WEB_ON_BRAVO="$( cluster_dataset bravo )/standby/alpha/web01"
WEB_ON_CHARLIE="$( cluster_dataset charlie )/standby/alpha/web01"

# --- tick one: both heirs, both fine ---------------------------------------

t_rc 0 "tick 1 replicates web01 to both heirs" -- node_seance alpha repl --now

TS1=$( newest_ours alpha "${ALPHA_DS}/web01" )
t_like "${TS1}" '^seance-alpha-[0-9]{8}T[0-9]{6}Z$' \
    "tick 1 left a wire-protocol snapshot on the source"
t_is "$( newest_ours charlie "${WEB_ON_CHARLIE}" )" "${TS1}" \
    "and charlie, the second heir, holds it"

# The epoch charlie's record carried after the good tick, kept so that "the
# record moved on" can be asserted against it. Not against bravo's: each pair
# runs in its own re-executed dispatcher under lockf (D-62) and asks the clock
# for itself, so two pairs of one tick legitimately carry epochs a second or
# two apart. What must be true is that the FAILED pair's record is newer than
# the last good one -- otherwise status reports a tick that succeeded minutes
# ago and exits 0 while replication is broken.
CLAG_TICK1=$( lag alpha web01 charlie | awk '{ print $2 }' )
t_like "${CLAG_TICK1}" '^[0-9]+$' \
    "charlie's record from the good tick carries a tick epoch to compare against"

# ---------------------------------------------------------------------------
# The cut
# ---------------------------------------------------------------------------
#
# A payload big enough that a full send of it takes seconds over the epair, and
# charlie's replica destroyed so that charlie's pair owes exactly that while
# bravo's owes an increment of one small file. /dev/random rather than
# /dev/zero: a compressible payload sends instantly and the window closes.

cluster_exec alpha dd if=/dev/random of=/seance/web01/data/bulk bs=1m count=256 \
    < /dev/null > /dev/null 2>&1 ||
    t_diag "writing the bulk payload failed"
cluster_exec alpha sh -c 'echo v2 >> /seance/web01/data/marker' < /dev/null

nz charlie destroy -r "${WEB_ON_CHARLIE}" ||
    t_diag "destroying charlie's replica failed"
t_rc 1 "charlie's replica is gone, so its next send is a full one" \
    -- nz charlie list -H -o name "${WEB_ON_CHARLIE}"

WORK=$( t_tmpdir )

# shellcheck disable=SC2086
#   Deliberate word splitting: ${SN_ENV} is a list of VAR=value words.
cluster_exec alpha env ${SN_ENV} "${SN_BIN}" repl --now \
    < /dev/null > "${WORK}/tick2.out" 2> "${WORK}/tick2.err" &
TICK_PID=$!

# Wait until charlie's own stream is OPEN, not merely until the tick has
# started. The receive creates the replica's child dataset as soon as the bulk
# stream begins, so its appearance is the signal that there is something in
# flight to cut. Waiting for bravo's snapshot instead would fire while bravo's
# own bulk send was still running and charlie's pair had not begun -- which
# tests the already-unreachable case the `repl` stage covers, wearing this
# stage's name.
i=0
CUT_OPEN=no
while [ "${i}" -lt 240 ]; do
    if nz charlie list -H -o name "${WEB_ON_CHARLIE}/data" > /dev/null 2>&1; then
        CUT_OPEN=yes
        break
    fi
    kill -0 "${TICK_PID}" 2>/dev/null || break
    i=$(( i + 1 ))
    sleep 0.5
done

t_is "${CUT_OPEN}" "yes" \
    "charlie's bulk stream was open when the cut was made: this is mid-stream"
t_is "$( lag alpha web01 bravo | awk '{ print $3 }' )" "0" \
    "and bravo's pair had already finished and recorded itself"

cluster_isolate charlie || t_diag "cluster_isolate charlie failed"

wait "${TICK_PID}"
TICK2_RC=$?
TICK2=$( cat "${WORK}/tick2.out" "${WORK}/tick2.err" )

TS2=$( newest_ours alpha "${ALPHA_DS}/web01" )

# --- what the tick said -----------------------------------------------------

t_isnt "${TICK2_RC}" "0" \
    "the tick's exit code reports the pair it lost"
t_like "${TICK2}" '^repl: 1 guests x 2 pairs, 1 ok, 1 failed, 0 skipped, 0 in progress$' \
    "and its verdict line counts one pair ok and one failed"

# --- the reachable pair still completed ------------------------------------

t_is "$( newest_ours bravo "${WEB_ON_BRAVO}" )" "${TS2}" \
    "bravo has the tick's snapshot: one heir dying did not cost the other"
t_is "$( lag alpha web01 bravo | awk '{ print $1 " " $3 }' )" \
    "${TS2#seance-alpha-} 0" \
    "and bravo's lag record names that snapshot with rc 0"

# --- the failed pair kept what it knew --------------------------------------

CLAG=$( lag alpha web01 charlie )
t_is "$( printf '%s' "${CLAG}" | awk '{ print $1 }' )" "${TS1#seance-alpha-}" \
    "charlie's lag record kept the timestamp charlie was last known to hold"
t_isnt "$( printf '%s' "${CLAG}" | awk '{ print $3 }' )" "0" \
    "and records that this tick failed"

CLAG_TICK2=$( printf '%s' "${CLAG}" | awk '{ print $2 }' )
t_rc 0 "the failed pair's record moved on: its epoch is past the last good tick's" \
    -- test "${CLAG_TICK2}" -gt "${CLAG_TICK1}"

# --- nothing was lost on the source ----------------------------------------

t_is "$( snaps alpha "${ALPHA_DS}/web01" | tr '\n' ' ' )" \
    "$( printf '%s\n%s\n' "${TS1}" "${TS2}" | LC_ALL=C sort | tr '\n' ' ' )" \
    "the source still holds both snapshots: a failed send destroys nothing here"

# The cut stream's remains, on the peer: a dataset that exists, carries no
# snapshot of the instant it was receiving, and holds the token that says where
# to continue. This is what makes the next tick a resume rather than a restart.
t_rc 0 "charlie kept the partially received dataset" \
    -- nz charlie list -H -o name "${WEB_ON_CHARLIE}/data"
t_isnt "$( nz charlie get -H -o value receive_resume_token \
        "${WEB_ON_CHARLIE}/data" )" "-" \
    "and a receive_resume_token: the stream died with bytes still owed"

# --- status agrees ----------------------------------------------------------

STATUS=$( node_seance alpha status --tsv 2>&1 )
STATUS_RC=$?
t_isnt "${STATUS_RC}" "0" "status refuses to exit 0 while a pair is broken"
t_like "${STATUS}" \
    "^replica${TAB}web01${TAB}charlie${TAB}${TS1#seance-alpha-}${TAB}[0-9]+${TAB}[a-zA-Z]+${TAB}[^0]" \
    "and reports charlie's replica at the timestamp it kept, with a non-zero rc"

# ---------------------------------------------------------------------------
# The heal
# ---------------------------------------------------------------------------

# The peer's half of the cut stream outlives the cut: removing charlie's port
# from the bridge drops packets, and charlie's `zfs recv` goes on waiting on a
# TCP connection that will not be told. Observed: healing immediately and
# ticking again meets "cannot receive resume stream: destination ... contains
# partially-complete state from zfs receive -s" -- the OLD receive still owns
# the dataset, and the new one cannot take it over.
#
# That is a fact about TCP, not about seance, and waiting minutes for a
# retransmit timer is not what this stage measures. So the peer's recovery is
# made explicit: end the orphaned receive, exactly as a reboot or a timeout
# eventually would. The token it leaves behind is the thing under test, and
# that it survives the kill is asserted rather than assumed.
cluster_exec charlie pkill -f 'zfs recv' < /dev/null 2>/dev/null
i=0
while [ "${i}" -lt 30 ]; do
    cluster_exec charlie pgrep -f 'zfs recv' < /dev/null > /dev/null 2>&1 || break
    i=$(( i + 1 ))
    sleep 1
done
t_rc 1 "the peer's orphaned receive is gone, as a reboot or a timeout would leave it" \
    -- cluster_exec charlie pgrep -f 'zfs recv'
t_isnt "$( nz charlie get -H -o value receive_resume_token \
        "${WEB_ON_CHARLIE}/data" )" "-" \
    "and the resume token survived it: the partial receive is still resumable"

cluster_heal charlie || t_diag "cluster_heal charlie failed"

t_rc 0 "charlie answers again after the heal" \
    -- cluster_exec alpha ping -c 1 -t 5 "$( cluster_ip charlie )"

t_rc 0 "the next tick puts the broken pair back" \
    -- node_seance alpha repl --guest web01 --peer charlie --now

# The healing tick is a full tick, so it takes a snapshot of its own before it
# sends: charlie therefore ends up with the instant the cut stream was carrying
# AND the new one. It does NOT get TS1 back, and must not -- the fixture
# destroyed charlie's replica, so TS1 is not in the resumed stream and inventing
# it would mean seance had sent something it did not have. What must be true is
# that the lineage is unbroken from the resume onwards.
TS3=$( newest_ours alpha "${ALPHA_DS}/web01" )
t_isnt "${TS3}" "${TS2}" "the healing tick took a snapshot of its own"
t_is "$( snaps charlie "${WEB_ON_CHARLIE}" | tr '\n' ' ' )" \
    "$( printf '%s\n%s\n' "${TS2}" "${TS3}" | LC_ALL=C sort | tr '\n' ' ' )" \
    "charlie's lineage is unbroken from the resumed instant onwards"
t_like "$( snaps charlie "${WEB_ON_CHARLIE}" | tr '\n' ' ' )" "${TS2}" \
    "including the snapshot the cut stream never delivered"

t_is "$( cluster_exec charlie zfs get -H -o value receive_resume_token \
        "${WEB_ON_CHARLIE}/data" < /dev/null )" "-" \
    "and the interrupted receive was finished, not left half-written"

# 'none' is only half the answer: a mountpoint of none whose SOURCE is local or
# received is a replica carrying one of its own, which is one edit away from
# the August defect. Asserted from ZFS's account of both.
CMP=$( nz charlie get -H -o value mountpoint "${WEB_ON_CHARLIE}" )
CSRC=$( nz charlie get -H -o source mountpoint "${WEB_ON_CHARLIE}" )
CCM=$( nz charlie get -H -o value canmount "${WEB_ON_CHARLIE}" )
t_is "${CMP}/${CCM}" "none/noauto" \
    "the replica that arrived through a broken stream is mountpoint=none canmount=noauto"
t_unlike "${CSRC}" '^(local|received)$' \
    "and carries no mountpoint of its own: the law survived the interruption"

# "ONCE BOTH PAIRS ARE GOOD" is a premise, and it is established rather than
# assumed: the healing tick above was --peer charlie only, so bravo's replica
# is whatever age this file has reached since tick 1 -- and the interrupted-
# stream section above can wait out a TCP timeout, which put bravo 30 minutes
# past a 180 s staleness_max on one run and failed this row about nothing.
t_rc 0 "a normal tick for the bravo pair, so that both pairs are good by construction" \
    -- node_seance alpha repl --guest web01 --peer bravo --now
t_rc 0 "status on alpha exits 0 again once both pairs are good" \
    -- node_seance alpha status

t_done
