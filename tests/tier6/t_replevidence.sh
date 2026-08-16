#!/bin/sh
# Tier 6, stage 'replevidence' -- what the engine does when the peer's answer
# is empty.
#
# The crashed-verifier class, in the replication path. A listing that comes
# back EMPTY WITH A SUCCESS STATUS is the defect shape this project has met
# before (TESTING.md §8), and in `repl` it arrives at a decision: the peer
# reports no snapshot on a replica, and the engine has to choose between
#
#   "the peer has nothing, so send the dataset in full", and
#   "the peer told me nothing, which is not the same thing at all".
#
# The two are indistinguishable from the snapshot list alone, and they are
# distinguishable from the DATASET list: a replica dataset exists only because
# a receive created it, and a receive always leaves the snapshot it carried. So
# a dataset the peer lists as present, with no snapshot of our lineage on it
# and no resume token, is evidence that could not be read -- and deciding on it
# is the thing to refuse.
#
# There are two ways to get it wrong and both cost something real:
#
#   * sending in full onto a dataset that already exists. zfs-receive(8)
#     refuses it, so the tick fails anyway -- but by accident, with a message
#     about a full send rather than about the peer, and only because ZFS
#     happens to be the backstop. The only flag that would make it "work" is
#     `-F`, which destroys whatever is on the peer; seance has no such
#     authority over another node's pool (D-64).
#
#   * writing "-" into the lag record. "Nothing in common" and "could not find
#     out what is in common" reach the record as the same empty string, and
#     recording the second as the first throws away the one number that says
#     what a promotion onto that peer would cost -- and stops the staleness
#     clock that would otherwise escalate.
#
# The fixture is real rather than injected: seance's snapshots are destroyed on
# the replica while its datasets are left in place. That is byte-for-byte the
# evidence a crashed lister produces, and it is also a state a pair of hands
# can produce, which is the better reason to handle it.
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

stage_begin replevidence

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the replevidence stage builds jails and ZFS datasets; it needs root"
    echo "t_replevidence: must run as root" >&2
    exit 2
fi

t_plan 22

TAB=$( printf '\t.' )
TAB=${TAB%.}

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

snaps()
{
    nz "$1" list -H -o name -t snapshot -r "$2" 2>/dev/null |
        sed 's/.*@//' | LC_ALL=C sort -u
}

lag()
{
    cluster_exec "$1" cat "/var/db/seance/lag/$2.$3" < /dev/null 2>/dev/null
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

TS1=$( snaps alpha "${WEB_SRC}" | grep '^seance-alpha-' | tail -1 )
t_like "${TS1}" '^seance-alpha-[0-9]{8}T[0-9]{6}Z$' "and left a snapshot to lose"
t_is "$( snaps bravo "${WEB_ON_BRAVO}" | tr '\n' ' ' )" "${TS1} " \
    "the replica holds it too"

LAG1=$( lag alpha web01 bravo )
t_is "$( printf '%s' "${LAG1}" | awk '{ print $1 " " $3 }' )" \
    "${TS1#seance-alpha-} 0" "and the lag record names it"

# ---------------------------------------------------------------------------
# The empty answer
# ---------------------------------------------------------------------------
#
# Every snapshot destroyed on the replica, every dataset left standing. The
# peer will answer the probe with its dataset list and no snapshots at all --
# which is exactly what a listing that crashed with a success status looks
# like from here.

cluster_exec alpha sh -c 'echo v2 >> /seance/web01/data/marker' < /dev/null

for s in $( snaps bravo "${WEB_ON_BRAVO}" ); do
    nz bravo destroy -r "${WEB_ON_BRAVO}@${s}" ||
        t_diag "destroying ${s} on the replica failed"
done

t_is "$( snaps bravo "${WEB_ON_BRAVO}" | tr '\n' ' ' )" "" \
    "the replica now reports no snapshots at all"
t_rc 0 "while its datasets are all still there" \
    -- nz bravo list -H -o name "${WEB_ON_BRAVO}/data"

TICK2=$( node_seance alpha repl --now 2>&1 )
TICK2_RC=$?
TS2=$( snaps alpha "${WEB_SRC}" | grep '^seance-alpha-' | tail -1 )

t_isnt "${TICK2_RC}" "0" "the tick refuses to call that a success"
t_like "${TICK2}" 'refusing to decide what to send on evidence this thin' \
    "and says so in those terms, rather than by way of a failed send"
t_like "${TICK2}" "holds ${WEB_ON_BRAVO} " \
    "naming the dataset the peer claims to have"
t_unlike "${TICK2}" "no snapshot in common for ${WEB_SRC}; sending it in full" \
    "it did NOT decide to send in full onto a dataset the peer already has"

t_rc 0 "the peer's datasets are untouched: seance destroyed nothing to recover" \
    -- nz bravo list -H -o name "${WEB_ON_BRAVO}/data"
t_is "$( snaps alpha "${WEB_SRC}" | tr '\n' ' ' )" \
    "$( printf '%s\n%s\n' "${TS1}" "${TS2}" | LC_ALL=C sort | tr '\n' ' ' )" \
    "and the source keeps its whole lineage"

# --- the record: what it must NOT have become ------------------------------

LAG2=$( lag alpha web01 bravo )
t_is "$( printf '%s' "${LAG2}" | awk '{ print $1 }' )" "${TS1#seance-alpha-}" \
    "the lag record KEPT the timestamp the peer was last known to hold"
t_isnt "$( printf '%s' "${LAG2}" | awk '{ print $1 }' )" "-" \
    "it did not record 'nothing' for an answer it could not read"
t_isnt "$( printf '%s' "${LAG2}" | awk '{ print $3 }' )" "0" \
    "and it records the failure"
t_rc 0 "the record moved on to this tick" \
    -- test "$( printf '%s' "${LAG2}" | awk '{ print $2 }' )" -gt \
            "$( printf '%s' "${LAG1}" | awk '{ print $2 }' )"

STATUS=$( node_seance alpha status --tsv 2>&1 )
STATUS_RC=$?
t_isnt "${STATUS_RC}" "0" "status refuses to exit 0 on it"
t_like "${STATUS}" "^replica${TAB}web01${TAB}bravo${TAB}${TS1#seance-alpha-}${TAB}" \
    "and still reports what bravo is known to hold, rather than NONE"

# ---------------------------------------------------------------------------
# The refusal is scoped, not blanket
# ---------------------------------------------------------------------------
#
# A dataset the peer has NEVER seen must still be sent in full -- that is how a
# first tick works, and how a guest that gains a child dataset gets it there
# (docs/repl-wire.md §8). The refusal above must not have taught the engine to
# refuse that too, so the replica is repaired the way an operator would (destroy
# it; the next tick rebuilds it) and a new child dataset is added at the same
# time.

nz bravo destroy -r "${WEB_ON_BRAVO}" || t_diag "destroying the replica failed"
nz alpha create "${WEB_SRC}/logs" || t_diag "web01's second child dataset"
cluster_exec alpha sh -c 'echo logs-v1 > /seance/web01/logs/marker' < /dev/null

TICK3=$( node_seance alpha repl --now 2>&1 )
TICK3_RC=$?
TS3=$( snaps alpha "${WEB_SRC}" | grep '^seance-alpha-' | tail -1 )

t_is "${TICK3_RC}" "0" "a tick to a peer that genuinely has nothing succeeds"
t_like "${TICK3}" 'sending it in full' \
    "by sending in full, which is still the right answer when there is no dataset there"
t_is "$( nz bravo list -H -o name -t filesystem -r "${WEB_ON_BRAVO}" |
        sed "s#^${WEB_ON_BRAVO}##" | LC_ALL=C sort | tr '\n' ' ' )" \
    " /data /logs /sys " \
    "the rebuilt replica has every dataset, the new child included"
t_is "$( lag alpha web01 bravo | awk '{ print $1 " " $3 }' )" \
    "${TS3#seance-alpha-} 0" \
    "and the lag record names the instant it delivered, with rc 0"

t_done
