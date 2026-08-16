#!/bin/sh
# Tier 6, stage 'hostileenv' -- status, verify and repl under a locale and a
# timezone that are not the developer's.
#
# Tier 2 runs the policy functions under two hostile environments because the
# timestamp is the wire protocol and is UTC always. This stage does the same
# thing one layer up, where the functions have verbs around them: a tick fired
# by cron on a node whose /etc/localtime is Asia/Kolkata must write the same
# snapshot name as one fired in UTC, and `status` must render the same screen
# in a UTF-8 locale as in C.
#
# The failure this catches is not hypothetical and is not loud. A timestamp
# that picked up a +05:30 offset produces a snapshot name that every other node
# reads as five and a half hours in the future -- which pol_age reports as a
# clock-skew violation, which makes the replica unpromotable, on exactly one
# node, discovered during the promotion. And a `sort` that took its order from
# a collation table reorders a listing the moment somebody's locale changes.
#
# Everything is compared BYTE FOR BYTE against the same command run in the
# harness's own environment, with the two fields that legitimately move -- the
# age of a replica and the position of the clock -- taken out by name rather
# than by fuzzy matching.
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

stage_begin hostileenv

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the hostileenv stage builds jails and ZFS datasets; it needs root"
    echo "t_hostileenv: must run as root" >&2
    exit 2
fi

t_plan 15

TAB=$( printf '\t.' )
TAB=${TAB%.}

SN_ADAPTER="/usr/local/seance/tests/cluster/adapter-pseudo.subr"
SN_ENV="SEANCE_CONF=/etc/seance.conf SEANCE_STATE_DIR=/var/db/seance SEANCE_RUN_DIR=/var/run/seance SEANCE_ADAPTER=${SN_ADAPTER}"
SN_BIN="/usr/local/seance/bin/seance"

ALT1="LC_ALL=C LANG=C TZ=Asia/Kolkata"
ALT2="LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 TZ=Pacific/Kiritimati"

node_sh()
{
    local _n

    _n=$1
    shift

    # shellcheck disable=SC2086
    #   Deliberate word splitting: ${SN_ENV} is a list of VAR=value words for
    #   env(1), each of which must arrive as its own argument.
    cluster_exec "${_n}" env ${SN_ENV} sh -c "$*" < /dev/null
}

# in_env <node> <env-words> <command...>  -- a seance verb under an environment.
in_env()
{
    local _n _e

    _n=$1
    _e=$2
    shift 2

    # shellcheck disable=SC2086
    #   Deliberate word splitting: both ${SN_ENV} and ${_e} are lists of
    #   VAR=value words for env(1).
    cluster_exec "${_n}" env ${SN_ENV} ${_e} "${SN_BIN}" "$@" < /dev/null
}

nz()
{
    local _n

    _n=$1
    shift

    cluster_exec "${_n}" zfs "$@" < /dev/null
}

# ---------------------------------------------------------------------------
# A two-node cluster with one guest
# ---------------------------------------------------------------------------

cluster_up 2 || { t_diag "cluster_up failed"; t_done; }

BASE_DS=$( cluster_base_dataset )
ALPHA_DS=$( cluster_dataset alpha )
WEB_SRC="${ALPHA_DS}/web01"

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
    mkdir -p "$( cluster_root "${n}" )/usr/local/etc/cron.d"
done

node_sh alpha ". ${SN_ADAPTER}; adapter_init && pseudo_guest_create web01 jail alpha" ||
    t_diag "creating web01 failed"
nz alpha create "${WEB_SRC}/data" || t_diag "web01's child dataset"

# --- preflight: the hostile environments are real --------------------------
#
# A timezone that is not installed and a locale that does not exist both fail
# open -- the process keeps its old behaviour -- so a pass under a make-believe
# environment would prove nothing at all.

t_isnt "$( cluster_exec alpha env TZ=Asia/Kolkata date +%z < /dev/null )" "+0000" \
    "Asia/Kolkata is installed inside the node and is not UTC"
t_isnt "$( cluster_exec alpha env TZ=Pacific/Kiritimati date +%z < /dev/null )" "+0000" \
    "Pacific/Kiritimati is installed inside the node and is not UTC"

# ---------------------------------------------------------------------------
# A tick fired under a non-UTC timezone
# ---------------------------------------------------------------------------

BEFORE=$( date -u +%s )
t_rc 0 "a tick runs under LC_ALL=C TZ=Asia/Kolkata" \
    -- in_env alpha "${ALT1}" repl --now
AFTER=$( date -u +%s )

SNAP=$( nz alpha list -H -o name -t snapshot -r "${WEB_SRC}" |
    sed 's/.*@//' | grep '^seance-alpha-' | LC_ALL=C sort | tail -1 )
TS=${SNAP#seance-alpha-}
SNAP_EPOCH=$( date -u -j -f '%Y%m%dT%H%M%SZ' "${TS}" +%s )

t_rc 0 "and the snapshot it wrote is stamped in UTC, not in the node's timezone" \
    -- test "${SNAP_EPOCH}" -ge "$(( BEFORE - 2 ))" -a \
            "${SNAP_EPOCH}" -le "$(( AFTER + 2 ))"

# The other half of the same assertion: half an hour is not a rounding error.
# Asia/Kolkata is UTC+05:30, so a leaked offset would land 19800 seconds out
# and would be caught above -- but this states the number, so a failure says
# what happened rather than only that something did.
t_rc 1 "an offset of 19800 seconds would have been a different snapshot entirely" \
    -- test "${SNAP_EPOCH}" -ge "$(( BEFORE + 19700 ))"

# The record status reads carries the same instant, not a localised one.
t_is "$( cluster_exec alpha cat /var/db/seance/lag/web01.bravo < /dev/null |
        awk '{ print $1 }' )" "${TS}" \
    "the lag record names that UTC instant"

# ---------------------------------------------------------------------------
# The reports, byte for byte, across three environments
# ---------------------------------------------------------------------------

for n in alpha bravo; do
    in_env "${n}" "" verify --render cron \
        > "$( cluster_root "${n}" )/usr/local/etc/cron.d/seance"
done

CRON_HOME=$( in_env alpha "" verify --render cron )
CRON_ALT1=$( in_env alpha "${ALT1}" verify --render cron )
CRON_ALT2=$( in_env alpha "${ALT2}" verify --render cron )
t_is "${CRON_ALT1}" "${CRON_HOME}" \
    "verify --render cron is byte-identical under LC_ALL=C TZ=Asia/Kolkata"
t_is "${CRON_ALT2}" "${CRON_HOME}" \
    "and under a UTF-8 locale in Pacific/Kiritimati"

# status --tsv, with the two fields that legitimately move taken out by name:
# the replica's age in seconds, and nothing else.
tsv_stable()
{
    printf '%s\n' "$1" | awk -F "${TAB}" -v OFS="${TAB}" \
        '$1 == "replica" { $5 = "AGE" } { print }'
}

TSV_HOME=$( tsv_stable "$( in_env alpha "" status --tsv )" )
TSV_ALT1=$( tsv_stable "$( in_env alpha "${ALT1}" status --tsv )" )
TSV_ALT2=$( tsv_stable "$( in_env alpha "${ALT2}" status --tsv )" )

t_is "${TSV_ALT1}" "${TSV_HOME}" \
    "status --tsv is byte-identical under LC_ALL=C TZ=Asia/Kolkata"
t_is "${TSV_ALT2}" "${TSV_HOME}" \
    "and under a UTF-8 locale in Pacific/Kiritimati"

# The timestamp column on its own, stated separately so that a failure says
# "the wire protocol moved" rather than "something in the screen moved".
ts_col()
{
    printf '%s\n' "$1" | awk -F "${TAB}" '$1 == "replica" { print $4 }'
}

t_is "$( ts_col "${TSV_ALT1}" )" "$( ts_col "${TSV_HOME}" )" \
    "the replica timestamps are the same instants under a non-UTC timezone"

in_env alpha "" status > /dev/null 2>&1
RC_HOME=$?
in_env alpha "${ALT1}" status > /dev/null 2>&1
RC_ALT1=$?
in_env alpha "${ALT2}" status > /dev/null 2>&1
RC_ALT2=$?
t_is "${RC_ALT1}/${RC_ALT2}" "${RC_HOME}/${RC_HOME}" \
    "status reaches the same verdict in all three environments"

CHECK_HOME=$( in_env alpha "" config --check 2>&1 )
CHECK_ALT2=$( in_env alpha "${ALT2}" config --check 2>&1 )
t_is "${CHECK_ALT2}" "${CHECK_HOME}" \
    "config --check says the same thing in a UTF-8 locale"

VERIFY_HOME=$( in_env alpha "" verify 2>&1 )
VERIFY_ALT1=$( in_env alpha "${ALT1}" verify 2>&1 )
t_is "$( printf '%s\n' "${VERIFY_ALT1}" | sed -e 's/is [0-9]*s away/is Ns away/' )" \
    "$( printf '%s\n' "${VERIFY_HOME}" | sed -e 's/is [0-9]*s away/is Ns away/' )" \
    "verify's whole report is the same under a non-UTC timezone"

# Nothing anywhere rendered a local time: no month name, no UTC offset.
t_unlike "${TSV_ALT1}${TSV_ALT2}$( printf '%s' "${VERIFY_ALT1}" )" \
    '(Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Oct|Nov|Dec|[+-][0-9]{4}$)' \
    "no output carries a month name or a UTC offset: dates are the protocol's"

t_done
