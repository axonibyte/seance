#!/bin/sh
# Tier 6, stage 'failback' -- bringing a guest home, against a real cluster.
#
# The stage builds its own world (every tier-6 stage is individually runnable,
# D-25), kills alpha, promotes its estate onto bravo, brings alpha back, and
# then does the thing this stage exists for.
#
# THE ASSERTION THAT MATTERS MOST is the refusal. The reverse stream lands in
# the origin's LIVE dataset with `zfs recv -F`, which rolls it back to the
# incremental base -- so anything written to the origin's copy since that base
# is destroyed by the receive. seance measures it and refuses. This stage
# FABRICATES those writes, requires the refusal, checks the byte count is not
# zero, and only then passes --discard-origin-writes and requires the decision
# to be recorded. A guard that has never been seen refusing is a guard nobody
# has measured.
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

stage_begin failback

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/fence.subr
. "${T_ROOT}/tests/cluster/lib/fence.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/estate.subr
. "${T_ROOT}/tests/cluster/lib/estate.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the failback stage builds jails and ZFS datasets; it needs root"
    echo "t_failback: must run as root" >&2
    exit 2
fi

t_plan 31

TAB=$( printf '\t.' )
TAB=${TAB%.}

estate_up || { t_diag "estate_up failed"; t_done; }

ALPHA_DS=$( cluster_dataset alpha )
WEB_ON_BRAVO=$( estate_replica_root bravo alpha web01 )

# ---------------------------------------------------------------------------
# Get to the state a failback starts from
# ---------------------------------------------------------------------------

t_rc 0 "a replication tick on alpha" -- estate_replicate

cluster_stop alpha || t_diag "cluster_stop alpha failed"

t_rc 0 "alpha's estate is promoted onto bravo" -- node_seance bravo promote alpha
t_rc 0 "and bravo is running web01" \
    -- cluster_exec bravo sh -c 'test -f /seance/web01/marker'

# The interim host writes, so that the failback has something to carry back.
node_sh bravo 'echo web01-written-on-bravo >> /seance/web01/marker' ||
    t_diag "writing on bravo failed"

# ---------------------------------------------------------------------------
# alpha comes back, and the gate holds its estate
# ---------------------------------------------------------------------------

estate_reboot alpha || t_diag "estate_reboot alpha failed"

GATE_OUT=$( t_tmpdir )/gate.out
node_seance alpha gate > "${GATE_OUT}" 2>&1
GATE_RC=$?

t_is "${GATE_RC}" "1" "the returning node's gate does not exit 0: it withheld something"
t_like "$( cat "${GATE_OUT}" )" '^gate: HELD web01 -- bravo claims it$' \
    "and it withheld web01 because bravo claims it"
t_is "$( node_seance alpha status --tsv | awk -F "${TAB}" '$1 == "guest" && $2 == "web01" { print $6 }' )" \
    "yes" "alpha reports web01 as HELD"

# ---------------------------------------------------------------------------
# THE REFUSAL: writes on the origin since the base
#
# The returning node's copy of the guest is rolled back by the receive. These
# bytes stand in for the crash debris a real returning node would carry.
# ---------------------------------------------------------------------------

node_sh alpha 'echo debris-from-the-crash >> /seance/web01/marker' ||
    t_diag "fabricating origin writes failed"
nz alpha get -H -o value written "${ALPHA_DS}/web01" > /dev/null

REFUSED=$( t_tmpdir )/refused.out
node_seance alpha failback web01 > "${REFUSED}" 2>&1
REFUSED_RC=$?

t_is "${REFUSED_RC}" "1" "failback REFUSES while the origin has writes the receive would destroy"
t_like "$( cat "${REFUSED}" )" '^failback: REFUSED -- [1-9][0-9]* byte\(s\) have been written here' \
    "and it prints how many bytes, not an adjective"
t_like "$( cat "${REFUSED}" )" 'seance failback web01 --discard-origin-writes' \
    "and names the flag that accepts the loss"

t_diag "the refusal, in full:"
sed -e 's/^/#   /' "${REFUSED}"

t_like "$( cat "${REFUSED}" )" 'is still RUNNING on bravo; nothing has been stopped' \
    "the PRE-FLIGHT guard is what refused: it measured before it stopped anything"

# THE REFUSAL COSTS NOTHING. The measurement is of the ORIGIN's datasets
# against a base the interim already has, so neither half needs the guest
# stopped -- and a guard whose refusal costs an outage is one people learn to
# route around (D-80).
t_rc 1 "the refusal left web01 RUNNING on bravo: it cost no outage" \
    -- cluster_exec bravo sh -c \
    "awk -F'\t' '\$1 == \"web01\" && \$5 == \"0\"' /var/db/seance-pseudo/guests.tsv | grep ."
t_rc 1 "and alpha has NOT started it either" \
    -- cluster_exec alpha sh -c \
    "awk -F'\t' '\$1 == \"web01\" && \$5 == \"1\"' /var/db/seance-pseudo/guests.tsv | grep ."

# ---------------------------------------------------------------------------
# The operator accepts the loss, deliberately and on the record
# ---------------------------------------------------------------------------

FB=$( t_tmpdir )/failback.out
node_seance alpha failback web01 --discard-origin-writes > "${FB}" 2>&1
FB_RC=$?

t_is "${FB_RC}" "0" "failback --discard-origin-writes completes"
t_like "$( cat "${FB}" )" '^failback: discarding [1-9][0-9]* byte\(s\)' \
    "and says how much it discarded"
t_like "$( cat "${FB}" )" '^failback: web01 is home on alpha and running' \
    "and ends in one verdict line"
t_like "$( cat "${FB}" )" '^  undo: ' \
    "every step printed its undo, including the one that has none"

# --- the data that came home -------------------------------------------------

t_stdout_is "web01-v1
web01-written-on-bravo" \
    "the interim host's writes came home, and the origin's debris did not" \
    -- cluster_exec alpha cat /seance/web01/marker

# --- the platform's account --------------------------------------------------

t_is "$( node_seance alpha status --tsv | awk -F "${TAB}" '$1 == "guest" && $2 == "web01" { print $5 "/" $6 }' )" \
    "yes/no" "web01 is running at home and no longer held"

t_rc 1 "bravo no longer has web01 registered" \
    -- cluster_exec bravo sh -c \
    "awk -F'\t' '\$1 == \"web01\"' /var/db/seance-pseudo/guests.tsv | grep ."

t_is "$( node_seance bravo placement | awk -F "${TAB}" '$1 == "placement" && $2 == "web01" { print $3 }' )" \
    "" "and bravo's placement no longer claims it"

# --- the replica on the interim is hidden again ------------------------------

t_is "$( nz bravo get -H -o value mountpoint "${WEB_ON_BRAVO}" )" "none" \
    "the replica on bravo is back to mountpoint=none"
t_is "$( nz bravo get -H -o value mounted "${WEB_ON_BRAVO}" )" "no" \
    "and unmounted -- a replica still mounted at the platform's paths is the shadow-mount hazard"

# --- the configuration came back too (D-82) ---------------------------------
#
# The mirror in reverse. bravo was web01's home for the length of the outage,
# so its own configuration mirror carries whatever the platform wrote there --
# and alpha holds a replica of it if bravo ticked at all after the promotion.
# In shape A the guests' configuration travels inside their own datasets, so
# failback says so rather than restoring; what is asserted is that it SAYS
# which of the two happened, because doing either silently is the failure.
# Shape A's guests carry their configuration inside their own datasets, so
# repl_sys_travels says so and the restore is not attempted at all. Claiming to
# have restored something that was never fetched would be the failure here.
t_unlike "$( cat "${FB}" )" 'restored web01 configuration from bravo' \
    "failback does not claim to restore a configuration that travelled with the data"

t_rc 0 "and web01's own configuration is readable at home, which is what registers it" \
    -- cluster_exec alpha test -r /seance/web01/sys/rc.conf_web01

# --- the record ---------------------------------------------------------------

SUCC_BRAVO=$( cluster_exec bravo cat /var/db/seance/succession.log < /dev/null )
t_like "${SUCC_BRAVO}" "^web01${TAB}bravo${TAB}alpha${TAB}[0-9]{8}T[0-9]{6}Z${TAB}failback\$" \
    "the interim closed the record with a failback entry"

SUCC_ALPHA=$( cluster_exec alpha cat /var/db/seance/succession.log < /dev/null )
t_like "${SUCC_ALPHA}" "^web01${TAB}bravo${TAB}alpha${TAB}[0-9]{8}T[0-9]{6}Z${TAB}discard:[1-9][0-9]*\$" \
    "and the origin recorded the discarded byte count as its evidence"

# ---------------------------------------------------------------------------
# Normal replication resumes, in the normal direction
# ---------------------------------------------------------------------------

# db01 is still held here and still running on bravo, so alpha must SKIP it
# rather than send its stale copy over the copy that is running. That skip is
# the fix this stage's first run found: without it every tick failed with
# "destination has been modified since most recent snapshot" until db01 was
# failed back too -- safe, because the forward direction never passes -F
# (D-64), but a fleet reported broken for as long as a promotion stood.
RESUMED=$( t_tmpdir )/resumed.out
node_seance alpha repl --now > "${RESUMED}" 2>&1
RESUMED_RC=$?

t_is "${RESUMED_RC}" "0" \
    "a replication tick on alpha exits 0, now that web01 is home again"
t_like "$( cat "${RESUMED}" )" '^notice: repl db01: held here, so another node is hosting it' \
    "and db01, which bravo is still running, is skipped rather than replicated over"
t_like "$( cat "${RESUMED}" )" '1 skipped' \
    "the verdict line counts it as skipped, not as a failure"

t_diag "interim lineage on the origin: $( nz alpha list -H -o name -t snapshot -r "${ALPHA_DS}/web01" | tr '\n' ' ' )"

t_like "$( nz bravo list -H -o name -t snapshot "${WEB_ON_BRAVO}" )" \
    '@seance-alpha-[0-9]{8}T[0-9]{6}Z$' \
    "bravo's replica of web01 carries alpha's lineage again"

# Restricted to the ROOT dataset: the reverse stream carries the interim's
# snapshot on every dataset of the tree, and counting all of them would be
# counting the tree rather than the lineage.
t_is "$( nz alpha list -H -o name -t snapshot -r "${ALPHA_DS}/web01" |
    awk -F '@' -v d="${ALPHA_DS}/web01" '$1 == d { print $2 }' |
    grep -c '^seance-bravo-' )" "1" \
    "the interim's lineage is on the origin, and exactly one snapshot of it survived retention"

t_done
