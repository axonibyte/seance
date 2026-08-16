#!/bin/sh
# Tier 6, stage 'report' -- the exit-code matrix of status and verify, and the
# stability of the machine-readable shape.
#
# The exit code IS the product for these two verbs: a monitoring check runs
# `seance status` every minute and reads nothing but the number. So every state
# a fleet can be in gets a row here, and each row asserts the code rather than
# the prose:
#
#   fresh          everything replicated, every peer answering        0
#   stale          a replica older than its staleness_max             1
#   unreachable    a peer that does not answer                        1
#   drift          a peer holding a different configuration file      1
#   invalid        a configuration that does not validate             2
#   foreign node   this node is not in its own configuration          2
#
# 1 and 2 are not interchangeable and the difference is the whole reason there
# are two: 1 is "the fleet has a problem", 2 is "seance cannot tell you anything
# about the fleet". A check that treats them alike will page for the first and
# stay silent through the second, which is the wrong way round.
#
# And the shape: --tsv is what a script reads, so a record type whose column
# count moves with the fleet's state is a parser that breaks on the day it
# matters. Every record type is counted in the good state and again in the
# broken one.
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

stage_begin report

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the report stage builds jails and ZFS datasets; it needs root"
    echo "t_report: must run as root" >&2
    exit 2
fi

t_plan 27

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

# cols <tsv> <record-type>  -- the distinct field counts of that record type.
cols()
{
    printf '%s\n' "$1" | awk -F "${TAB}" -v t="$2" '$1 == t { print NF }' |
        LC_ALL=C sort -u | tr '\n' ' '
}

# ---------------------------------------------------------------------------
# A good fleet
# ---------------------------------------------------------------------------

cluster_up 2 || { t_diag "cluster_up failed"; t_done; }

BASE_DS=$( cluster_base_dataset )
ALPHA_DS=$( cluster_dataset alpha )
WEB_SRC="${ALPHA_DS}/web01"

CONF=$( t_tmpdir )/seance.conf
cat > "${CONF}" <<EOF
cadence=60
staleness_max=180
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
    mkdir -p "$( cluster_root "${n}" )/usr/local/etc/cron.d"
done

node_sh alpha ". ${SN_ADAPTER}; adapter_init && pseudo_guest_create web01 jail alpha" ||
    t_diag "creating web01 failed"
nz alpha create "${WEB_SRC}/data" || t_diag "web01's child dataset"

t_rc 0 "a first tick replicates the guest" -- node_seance alpha repl --now

for n in alpha bravo; do
    node_seance "${n}" verify --render cron \
        > "$( cluster_root "${n}" )/usr/local/etc/cron.d/seance"
done

# --- fresh ------------------------------------------------------------------

t_rc 0 "fresh: status exits 0" -- node_seance alpha status
t_rc 0 "fresh: verify exits 0" -- node_seance alpha verify

GOOD_TSV=$( node_seance alpha status --tsv )

# --- the rendering is a pure function of the configuration ------------------

CRON1=$( node_seance alpha verify --render cron )
CRON2=$( node_seance alpha verify --render cron )
t_is "${CRON1}" "${CRON2}" \
    "verify --render cron is byte-stable across two runs"
t_like "${CRON1}" '^\*/1 \* \* \* \* root /usr/local/seance/bin/seance repl$' \
    "and is the crontab(5) system line it claims to be"
t_rc 2 "verify --render of a subject it does not know is a contract error" \
    -- node_seance alpha verify --render nonsense

# ---------------------------------------------------------------------------
# stale
# ---------------------------------------------------------------------------
#
# The lag record is what status reads (design §5), so the way to age a replica
# without waiting is to age the record: staleness_max is 180 s, so a record
# timestamped an hour ago is stale by any reading.

OLD_TS=$( cluster_exec alpha date -u -r "$(( $( date -u +%s ) - 3600 ))" \
    +%Y%m%dT%H%M%SZ < /dev/null )
node_sh alpha "printf '%s %s 0\n' ${OLD_TS} $( date -u +%s ) > /var/db/seance/lag/web01.bravo"

STALE=$( node_seance alpha status 2>&1 )
STALE_RC=$?
t_is "${STALE_RC}" "1" "stale: status exits 1"
t_like "${STALE}" '^WARN replica web01@bravo: .* past staleness_max 180s$' \
    "and names the replica, its age and the threshold it passed"
t_like "$( node_seance alpha status --tsv )" \
    "^replica${TAB}web01${TAB}bravo${TAB}${OLD_TS}${TAB}[0-9]+${TAB}STALE${TAB}" \
    "the machine-readable form says STALE in the verdict column"

t_rc 0 "a tick puts it back" -- node_seance alpha repl --now
t_rc 0 "and status is 0 again" -- node_seance alpha status

# ---------------------------------------------------------------------------
# unreachable
# ---------------------------------------------------------------------------

cluster_isolate bravo || t_diag "cluster_isolate bravo failed"

UNREACH=$( node_seance alpha status 2>&1 )
UNREACH_RC=$?
t_is "${UNREACH_RC}" "1" "unreachable: status exits 1"
t_like "${UNREACH}" '^WARN peer bravo did not answer$' "and says which peer"

UNREACH_TSV=$( node_seance alpha status --tsv 2>&1 )

VERIFY_UNREACH=$( node_seance alpha verify 2>&1 )
VERIFY_UNREACH_RC=$?
t_is "${VERIFY_UNREACH_RC}" "1" "unreachable: verify exits 1"
t_like "${VERIFY_UNREACH}" '^FAIL mesh: alpha -> bravo .* does not answer ssh$' \
    "and reports the mesh edge that is down, as a FAIL"

cluster_heal bravo || t_diag "cluster_heal bravo failed"

# ---------------------------------------------------------------------------
# the shape does not move with the state
# ---------------------------------------------------------------------------

for rec in node guest replica carp peer; do
    t_is "$( cols "${GOOD_TSV}" "${rec}" )" "$( cols "${UNREACH_TSV}" "${rec}" )" \
        "--tsv: the ${rec} record has the same column count in both states"
done

# ---------------------------------------------------------------------------
# drift
# ---------------------------------------------------------------------------

printf '\n# a well-meaning edit, on one node only\ndebounce=30\n' \
    >> "$( cluster_root bravo )/etc/seance.conf"

DRIFT=$( node_seance alpha status 2>&1 )
DRIFT_RC=$?
t_is "${DRIFT_RC}" "1" "drift: status exits 1"
t_like "${DRIFT}" '^FAIL peer bravo: CONFIGURATION DIFFERS' \
    "and it is a FAIL, in capitals, not a footnote"

t_rc 1 "drift: verify exits 1 too" -- node_seance alpha verify

cp "${CONF}" "$( cluster_root bravo )/etc/seance.conf"

# ---------------------------------------------------------------------------
# the contract errors: 2, not 1
# ---------------------------------------------------------------------------

printf 'cadence=1\n' > "$( cluster_root alpha )/etc/seance-broken.conf"

t_rc 2 "invalid configuration: status exits 2, not 1" \
    -- node_sh alpha "SEANCE_CONF=/etc/seance-broken.conf ${SN_BIN} status"
t_rc 2 "invalid configuration: verify exits 2, not 1" \
    -- node_sh alpha "SEANCE_CONF=/etc/seance-broken.conf ${SN_BIN} verify"

# A configuration that is perfectly valid and does not mention this node. Every
# number below it would be about somebody else's fleet.
sed -e 's/^node_alpha_nodename=alpha$/node_alpha_nodename=someoneelse/' \
    "${CONF}" > "$( cluster_root alpha )/etc/seance-elsewhere.conf"

t_rc 2 "a node that is not in its own configuration: status exits 2" \
    -- node_sh alpha "SEANCE_CONF=/etc/seance-elsewhere.conf ${SN_BIN} status"
t_rc 2 "and verify exits 2" \
    -- node_sh alpha "SEANCE_CONF=/etc/seance-elsewhere.conf ${SN_BIN} verify"

t_done
