#!/bin/sh
# Tier 6, stage 'retention' -- pruning a dataset somebody else also keeps
# snapshots in.
#
# The `repl` stage proves the ladder and proves that a foreign snapshot at each
# END of it survives. This stage puts foreign names BETWEEN ours, at every rung
# and on both sides of every boundary, and adds the class that is easiest to
# get wrong: names that look exactly like seance's own and are not.
#
#     seance-alpha-20260229T101500Z    February 29th of a year that has none
#     seance-alpha-20261332T000000Z    month 13, day 32
#     seance-alpha-20260816T101500     no Z, so not UTC-looking
#     seance-alpha-notatime            no timestamp at all
#     seance-bravo-<old>               ours in shape, another node's lineage
#
# Every one of those parses as FOREIGN (handoff §2.1, D-42) and foreign means
# "somebody else's, leave it alone" -- not "unparseable, therefore prunable".
# The complement of an incomplete keep list is a destructive instruction, which
# is why pol_retention refuses a list it cannot read rather than pruning what
# is left (D-38), and why this stage counts what survived rather than what went.
#
# The last of those five is the one with teeth. `seance-bravo-<ts>` is a
# perfectly well-formed name of OUR protocol belonging to ANOTHER node's
# lineage, sitting in a dataset alpha is pruning. Destroying it would be seance
# destroying seance's own evidence -- the replica bravo would promote from --
# and no exception would be raised anywhere.
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

stage_begin retention

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the retention stage builds jails and ZFS datasets; it needs root"
    echo "t_retention: must run as root" >&2
    exit 2
fi

t_plan 16

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

has()
{
    printf '%s\n' "$1" | grep -q -x -F "$2"
}

# ---------------------------------------------------------------------------
# A two-node cluster with one guest
# ---------------------------------------------------------------------------

cluster_up 2 || { t_diag "cluster_up failed"; t_done; }

BASE_DS=$( cluster_base_dataset )
ALPHA_DS=$( cluster_dataset alpha )
ARC_SRC="${ALPHA_DS}/arc01"
ARC_REP="$( cluster_dataset bravo )/standby/alpha/arc01"

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

node_sh alpha ". ${SN_ADAPTER}; adapter_init && pseudo_guest_create arc01 jail alpha" ||
    t_diag "creating arc01 failed"

t_rc 0 "a first tick establishes the replica" -- node_seance alpha repl --now

# ---------------------------------------------------------------------------
# The ladder, with foreign names threaded through it
# ---------------------------------------------------------------------------

NOW=$( date -u +%s )
ts_at() { date -u -r "$1" +%Y%m%dT%H%M%SZ; }

# Ours: one five days old (past every window), two in one hour bucket ten hours
# back (only the newer survives), and whatever the first tick left (recent).
TS_ANCIENT=$( ts_at $(( NOW - 5 * 86400 )) )
HOUR=$(( ( NOW - 36000 ) / 3600 * 3600 ))
TS_MID1=$( ts_at $(( HOUR + 300 )) )
TS_MID2=$( ts_at $(( HOUR + 3300 )) )

OURS="seance-alpha-${TS_ANCIENT} seance-alpha-${TS_MID1} seance-alpha-${TS_MID2}"

# Foreign, threaded between ours at every rung, and at both ends of the range.
FOREIGN="zrepl-19990101T000000
zrepl-$( ts_at $(( NOW - 6 * 86400 )) )
zrepl-$( ts_at $(( NOW - 5 * 86400 + 60 )) )
zrepl-$( ts_at $(( HOUR + 600 )) )
zrepl-$( ts_at $(( HOUR + 3000 )) )
zrepl-$( ts_at $(( NOW - 60 )) )
zfs-auto-snap_daily-2026-08-16-1015
manual-before-upgrade"

# Ours in shape, not ours in fact: four that cannot be parsed as a timestamp,
# and one that parses perfectly and belongs to bravo.
LOOKALIKE="seance-alpha-20260229T101500Z
seance-alpha-20261332T000000Z
seance-alpha-20260816T101500
seance-alpha-notatime
seance-bravo-${TS_ANCIENT}"

for s in ${OURS}; do
    nz alpha snapshot -r "${ARC_SRC}@${s}" || t_diag "fabricating ${s} on the source"
    nz bravo snapshot -r "${ARC_REP}@${s}" || t_diag "fabricating ${s} on the replica"
done

for s in ${FOREIGN} ${LOOKALIKE}; do
    nz alpha snapshot -r "${ARC_SRC}@${s}" || t_diag "planting ${s} on the source"
    nz bravo snapshot -r "${ARC_REP}@${s}" || t_diag "planting ${s} on the replica"
done

SRC_BEFORE=$( snaps alpha "${ARC_SRC}" )
REP_BEFORE=$( snaps bravo "${ARC_REP}" )
t_rc 0 "the fixture planted every name on the source" \
    -- test "$( printf '%s\n' "${SRC_BEFORE}" | grep -c . )" -ge 16
t_is "${SRC_BEFORE}" "${REP_BEFORE}" \
    "and both ends start from the same set of names"

# --locked: do this pair and take no new snapshot, so the ladder is applied to
# the lineage this stage built rather than to one a tick has just made.
t_rc 0 "a prune-only tick over arc01 -> bravo" \
    -- node_seance alpha repl --guest arc01 --peer bravo --locked

SRC_AFTER=$( snaps alpha "${ARC_SRC}" )
REP_AFTER=$( snaps bravo "${ARC_REP}" )

# --- ours: pruned exactly as the ladder says -------------------------------

t_rc 1 "the five-day-old snapshot of ours is gone from the source" \
    -- has "${SRC_AFTER}" "seance-alpha-${TS_ANCIENT}"
t_rc 1 "and from the replica" \
    -- has "${REP_AFTER}" "seance-alpha-${TS_ANCIENT}"
t_rc 1 "the older of the two in one hour bucket is gone from the source" \
    -- has "${SRC_AFTER}" "seance-alpha-${TS_MID1}"
t_rc 0 "the newer of that hour survived on the source" \
    -- has "${SRC_AFTER}" "seance-alpha-${TS_MID2}"
t_rc 0 "and on the replica" \
    -- has "${REP_AFTER}" "seance-alpha-${TS_MID2}"

# --- foreign: every one of them, both ends ---------------------------------

MISSING_SRC=""
MISSING_REP=""
for s in ${FOREIGN} ${LOOKALIKE}; do
    has "${SRC_AFTER}" "${s}" || MISSING_SRC="${MISSING_SRC} ${s}"
    has "${REP_AFTER}" "${s}" || MISSING_REP="${MISSING_REP} ${s}"
done

t_is "${MISSING_SRC}" "" \
    "every foreign name survived on the source, interleaved rungs and all"
t_is "${MISSING_REP}" "" "and every one of them survived on the replica"

# The one with teeth, called out on its own so a failure names it.
t_rc 0 "bravo's own lineage, sitting in alpha's dataset, was not alpha's to prune" \
    -- has "${SRC_AFTER}" "seance-bravo-${TS_ANCIENT}"
t_rc 0 "a name shaped like ours whose date does not exist was left alone" \
    -- has "${SRC_AFTER}" "seance-alpha-20260229T101500Z"

# --- count the resource ----------------------------------------------------
#
# Exactly two snapshots were destroyed at each end, and they are the two the
# ladder names. Counted rather than inferred: a prune that destroyed the right
# two and one more besides would satisfy every assertion above.

t_is "$( printf '%s\n%s\n' "${SRC_BEFORE}" "${SRC_AFTER}" |
        LC_ALL=C sort | uniq -u | tr '\n' ' ' )" \
    "seance-alpha-${TS_ANCIENT} seance-alpha-${TS_MID1} " \
    "exactly two snapshots were destroyed on the source, and those two"
t_is "$( printf '%s\n%s\n' "${REP_BEFORE}" "${REP_AFTER}" |
        LC_ALL=C sort | uniq -u | tr '\n' ' ' )" \
    "seance-alpha-${TS_ANCIENT} seance-alpha-${TS_MID1} " \
    "and exactly the same two on the replica"

t_is "${SRC_AFTER}" "${REP_AFTER}" \
    "the two ends came out of it holding the same names"

t_done
