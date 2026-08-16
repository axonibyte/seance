#!/bin/sh
# Tier 6, stage 'replconc' -- two ticks at once on one node.
#
# A crontab line and an operator's `seance repl --now` do not take turns, and
# neither do two crontab lines on a node whose clock has just been stepped. So
# this stage runs two ticks concurrently and counts THE RESOURCE, not the exit
# codes: how many snapshots of one instant exist on the source, how many
# streams reached the peer, what the replica's lineage looks like afterwards.
# Asserting from the responses is how a suite comes to believe two processes
# co-operated because both of them said so.
#
# Two collisions, and they are different:
#
#   * SAME INSTANT. Both ticks ask the clock in the same second, so both
#     compute the same snapshot name. `zfs snapshot -r` is atomic and one of
#     them loses. What must NOT happen is the loser calling that a failure:
#     the snapshot the tick needed exists, taken by its twin, at exactly the
#     instant it asked for. A tick that exits 1 because somebody else did its
#     work is a tick that pages somebody at 03:00 for nothing, and worse,
#     teaches them that repl's exit code does not mean much.
#
#   * SAME PAIR. Two ticks a second apart both snapshot successfully and then
#     race for one guest-peer lock. lockf(1) hands it to one; the other must
#     stand down, report the pair as in progress rather than failed, and exit
#     0 -- and exactly one stream must have run, which is asserted from the
#     replica's own state and not from what either process claimed.
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

stage_begin replconc

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the replconc stage builds jails and ZFS datasets; it needs root"
    echo "t_replconc: must run as root" >&2
    exit 2
fi

t_plan 22

SN_ADAPTER="/usr/local/seance/tests/cluster/adapter-pseudo.subr"
SN_ENV="SEANCE_CONF=/etc/seance.conf SEANCE_STATE_DIR=/var/db/seance SEANCE_RUN_DIR=/var/run/seance SEANCE_ADAPTER=${SN_ADAPTER}"
SN_BIN="/usr/local/seance/bin/seance"

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

# snaps <node> <dataset> -- the short names under a dataset tree, deduplicated.
snaps()
{
    nz "$1" list -H -o name -t snapshot -r "$2" 2>/dev/null |
        sed 's/.*@//' | LC_ALL=C sort -u
}

# ---------------------------------------------------------------------------
# A two-node cluster with one guest
# ---------------------------------------------------------------------------

cluster_up 2 || { t_diag "cluster_up failed"; t_done; }

BASE_DS=$( cluster_base_dataset )
ALPHA_DS=$( cluster_dataset alpha )
WEB_SRC="${ALPHA_DS}/web01"
WEB_ON_BRAVO="$( cluster_dataset bravo )/standby/alpha/web01"

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

node_bravo_nodename=bravo
node_bravo_mgmt=$( cluster_ip bravo )
node_bravo_heir=alpha
EOF

for n in alpha bravo; do
    cp "${CONF}" "$( cluster_root "${n}" )/etc/seance.conf"
done

node_sh alpha ". ${SN_ADAPTER}; adapter_init && pseudo_guest_create web01 jail alpha" ||
    t_diag "creating web01 failed"
nz alpha create "${WEB_SRC}/data" || t_diag "web01's child dataset"
cluster_exec alpha sh -c 'echo v1 > /seance/web01/data/marker' < /dev/null

t_rc 0 "a first tick establishes the lineage" -- node_seance alpha repl --now

DS_COUNT=$( nz alpha list -H -o name -t filesystem -r "${WEB_SRC}" | wc -l | tr -d ' ' )
t_rc 0 "the guest has more than one dataset, so 'recursive' means something" \
    -- test "${DS_COUNT}" -gt 1

# ---------------------------------------------------------------------------
# Collision one: the same instant
# ---------------------------------------------------------------------------
#
# Both ticks are started by one shell, microseconds apart, so they almost
# always land in the same second. "Almost always" is not good enough to assert
# against, so the round is repeated until the collision is OBSERVED -- one new
# snapshot where two processes each meant to take one -- and the stage fails
# loudly if it never is, rather than passing on a round that never collided.

ATTEMPTS=0
COLLIDED=no
NEWSNAP=""
OUT_A=""
OUT_B=""
RC_A=""
RC_B=""

while [ "${ATTEMPTS}" -lt 6 ]; do
    ATTEMPTS=$(( ATTEMPTS + 1 ))

    BEFORE=$( snaps alpha "${WEB_SRC}" )

    node_sh alpha "{ ${SN_BIN} repl --now > /tmp/a.out 2>&1; echo \$? > /tmp/a.rc; } &
        { ${SN_BIN} repl --now > /tmp/b.out 2>&1; echo \$? > /tmp/b.rc; } &
        wait" > /dev/null 2>&1

    AFTER=$( snaps alpha "${WEB_SRC}" )
    NEW=$( printf '%s\n' "${BEFORE}
${AFTER}" | LC_ALL=C sort | uniq -u )
    NEWCOUNT=$( printf '%s' "${NEW}" | grep -c . )

    RC_A=$( cluster_exec alpha cat /tmp/a.rc < /dev/null 2>/dev/null )
    RC_B=$( cluster_exec alpha cat /tmp/b.rc < /dev/null 2>/dev/null )
    OUT_A=$( cluster_exec alpha cat /tmp/a.out < /dev/null 2>/dev/null )
    OUT_B=$( cluster_exec alpha cat /tmp/b.out < /dev/null 2>/dev/null )

    if [ "${NEWCOUNT}" -eq 1 ]; then
        COLLIDED=yes
        NEWSNAP=${NEW}
        break
    fi

    t_diag "attempt ${ATTEMPTS}: the two ticks landed in different seconds" \
        "(${NEWCOUNT} new snapshots); retrying"
done

t_is "${COLLIDED}" "yes" \
    "two ticks started together landed in the same second, as a cron and an operator would"

t_is "$( printf '%s' "${NEWSNAP}" | grep -c . )" "1" \
    "exactly ONE snapshot of that instant exists on the source, counted from zfs list"

# The recursive snapshot is atomic or it is nothing: every dataset of the guest
# carries the instant, or the replica it produces is not a point in time.
t_is "$( nz alpha list -H -o name -t snapshot -r "${WEB_SRC}" |
        grep -c "@${NEWSNAP}\$" )" "${DS_COUNT}" \
    "and every dataset of the guest carries it: the recursive snapshot stayed atomic"

t_is "${RC_A}/${RC_B}" "0/0" \
    "neither tick called the other's work a failure"

t_unlike "${OUT_A}${OUT_B}" 'zfs snapshot -r .* failed' \
    "and neither logged the snapshot step as failed"

t_like "${OUT_A}${OUT_B}" "already exists" \
    "the tick that lost the race said so, naming the instant its twin took"

t_like "${OUT_A}${OUT_B}" '^repl: 1 guests x 1 pairs, 1 ok, 0 failed' \
    "the tick that won reports one pair, done"

t_is "$( snaps bravo "${WEB_ON_BRAVO}" | grep -c -x -F "${NEWSNAP}" )" "1" \
    "the replica received that instant exactly once"

t_is "$( nz bravo get -H -o value receive_resume_token "${WEB_ON_BRAVO}/data" )" \
    "-" \
    "and the replica holds no half-written stream: only one receive ever ran"

t_is "$( cluster_exec alpha cat /var/db/seance/lag/web01.bravo < /dev/null |
        awk '{ print $1 " " $3 }' )" "${NEWSNAP#seance-alpha-} 0" \
    "the lag record names that instant, with rc 0"

# ---------------------------------------------------------------------------
# Collision two: the same pair
# ---------------------------------------------------------------------------
#
# A payload large enough that the first tick's stream is still open when the
# second starts, so the second meets a held lock rather than a finished one.

cluster_exec alpha dd if=/dev/random of=/seance/web01/data/bulk bs=1m count=256 \
    < /dev/null > /dev/null 2>&1 ||
    t_diag "writing the bulk payload failed"

BEFORE2=$( snaps alpha "${WEB_SRC}" )

# shellcheck disable=SC2086
#   Deliberate word splitting: ${SN_ENV} is a list of VAR=value words.
cluster_exec alpha env ${SN_ENV} "${SN_BIN}" repl --now \
    < /dev/null > /dev/null 2>&1 &
SLOW_PID=$!

# Wait until that tick's stream is genuinely in flight: the receive creates the
# replica's child dataset's new state, and the lock file is held. The lock is
# the thing being contended, so the lock is what is waited on.
i=0
LOCKED=no
while [ "${i}" -lt 240 ]; do
    if cluster_exec alpha lockf -s -t 0 /var/run/seance/lock/web01.bravo true \
            < /dev/null > /dev/null 2>&1; then
        :
    else
        LOCKED=yes
        break
    fi
    kill -0 "${SLOW_PID}" 2>/dev/null || break
    i=$(( i + 1 ))
    sleep 0.2
done

t_is "${LOCKED}" "yes" "the first tick is holding the web01->bravo lock"

# THE PREMISE OF THE SNAPSHOT ASSERTION BELOW, MADE TRUE RATHER THAN HOPED FOR.
# "Two ticks a second apart took two instants" is only a statement about the
# lock if the two ticks really are in different seconds; land them both in one
# and D-87 is what gets measured instead -- the second tick finds the instant
# already taken, replicates it, and there is one new snapshot rather than two.
# Nothing here enforced that, so the assertion turned on where a second
# boundary happened to fall relative to how long the first tick takes to reach
# the lock. It failed the moment M2 put a little more work in front of that
# (the configuration mirror, D-82), which is the test telling the truth about
# itself. Waiting out the current second costs at most a second and makes the
# sentence the assertion is written in true.
_conc_second=$( date -u +%s )
while [ "$( date -u +%s )" = "${_conc_second}" ]; do
    sleep 0.1
done

SECOND=$( node_seance alpha repl --now 2>&1 )
SECOND_RC=$?

t_is "${SECOND_RC}" "0" \
    "a tick that finds the pair locked is not a tick that failed"
t_like "${SECOND}" 'another tick holds this pair; skipped' \
    "it says the pair is somebody else's right now"
t_like "${SECOND}" '^repl: 1 guests x 1 pairs, 0 ok, 0 failed, 0 skipped, 1 in progress$' \
    "and counts it as in progress rather than as done or as failed"

wait "${SLOW_PID}"
SLOW_RC=$?
t_is "${SLOW_RC}" "0" "the tick that held the lock finished normally"

AFTER2=$( snaps alpha "${WEB_SRC}" )
NEW2=$( printf '%s\n' "${BEFORE2}
${AFTER2}" | LC_ALL=C sort | uniq -u )

t_is "$( printf '%s' "${NEW2}" | grep -c . )" "2" \
    "two ticks a second apart took two instants: neither was silently dropped"

t_is "$( nz bravo get -H -o value receive_resume_token "${WEB_ON_BRAVO}/data" )" \
    "-" \
    "exactly one receive ran for the pair: the replica holds no partial state"

# The lock is lockf's, so it is gone with the process that held it -- no stale
# file to steal on a liveness guess (D-62). Asked the only honest way: by
# taking it.
t_rc 0 "the lock was released with the process that held it" \
    -- cluster_exec alpha lockf -s -t 0 /var/run/seance/lock/web01.bravo true

t_rc 0 "a following tick delivers the instant the skipped tick took" \
    -- node_seance alpha repl --now

t_is "$( snaps bravo "${WEB_ON_BRAVO}" | tr '\n' ' ' )" \
    "$( snaps alpha "${WEB_SRC}" | tr '\n' ' ' )" \
    "and the replica's lineage is the source's again, nothing lost to the race"

t_done
