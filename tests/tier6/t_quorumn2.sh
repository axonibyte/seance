#!/bin/sh
# Tier 6, stage 'quorumn2' -- a two-node site, which is the shape most sites are.
#
# `quorum` isolates a node in a THREE-node cluster and asserts that the isolated
# one does nothing. This stage is the other half of the even-N doctrine, and it
# is the arrangement tenant zero actually runs: two nodes, and the moment one of
# them dies the survivor cannot form a majority with anybody. `1 + 0 > 2/2` is
# false, so the ladder FREEZES -- always, because v1 has no witness (design §3,
# and pol_quorum's own table) -- and a human decides.
#
# What is asserted here is the whole of that path against a real cluster, in
# both directions:
#
#   * the freeze: rung 2 stops, nothing is fenced, nothing is registered,
#     nothing is recorded, and the message names the command that continues;
#   * the force: `--force=quorum` skips exactly that rung -- the fence still
#     runs, the corpse is still verified off, and the evidence in the record is
#     `fence:jail` and NOT `force:<operator>`, because what was forced was the
#     arithmetic and not the fencing (D-68's distinction, measured).
#
# The configuration is written here rather than by estate_write_conf, which
# describes a three-node fleet: with charlie in the file and not in the
# cluster, N would be 3 and the arithmetic under test would be somebody else's.
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

stage_begin quorumn2

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
    t_diag "the quorumn2 stage builds jails and ZFS datasets; it needs root"
    echo "t_quorumn2: must run as root" >&2
    exit 2
fi

t_plan 24

TAB=$( printf '\t.' )
TAB=${TAB%.}

# --- a two-node world -------------------------------------------------------

cluster_up 2 || { t_diag "cluster_up 2 failed"; t_done; }

CONF=$( t_tmpdir )/seance.conf
cat > "${CONF}" <<EOF
cadence=60
retention_recent=14400
retention_hourly=172800
skew_tolerance=120
fence_timeout=90
ssh_user=root
ssh_port=22
ssh_extra_opts=-i /root/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
standby_root=$( cluster_base_dataset )/%n/standby

node_alpha_nodename=alpha
node_alpha_mgmt=$( cluster_ip alpha )
node_alpha_heir=bravo
node_alpha_fence_driver=jail
node_alpha_fence_target=alpha

node_bravo_nodename=bravo
node_bravo_mgmt=$( cluster_ip bravo )
node_bravo_heir=alpha
node_bravo_fence_driver=jail
node_bravo_fence_target=bravo
EOF

for n in alpha bravo; do
    cp "${CONF}" "$( cluster_root "${n}" )/etc/seance.conf" ||
        t_diag "installing the configuration on ${n} failed"
    mkdir -p "$( cluster_root "${n}" )/usr/local/etc/cron.d"
    estate_install_wrapper "${n}" || t_diag "installing seance on ${n} failed"
done

fence_install || t_diag "fence_install failed"
t_at_exit 'fence_uninstall'

t_rc 0 "a two-node fleet validates" -- node_seance alpha config --check

estate_guest_create alpha web01 jail alpha || t_diag "creating web01 failed"
node_sh alpha 'echo web01-n2 > /seance/web01/marker' ||
    t_diag "seeding web01 failed"

t_rc 0 "a replication tick on alpha" -- node_seance alpha repl --now

WEB_ON_BRAVO=$( estate_replica_root bravo alpha web01 )
t_rc 0 "web01 has a replica on bravo, its only heir" \
    -- nz bravo list -H -o name "${WEB_ON_BRAVO}"

# --- alpha dies -------------------------------------------------------------

cluster_stop alpha || t_diag "cluster_stop alpha failed"

t_rc 1 "alpha's jail is gone from the guest host's jls" \
    -- jls -d -j "$( cluster_jail_name alpha )" jid

# ---------------------------------------------------------------------------
# THE FREEZE
# ---------------------------------------------------------------------------

FREEZE=$( t_tmpdir )/freeze.out
node_seance bravo promote alpha > "${FREEZE}" 2>&1
FREEZE_RC=$?

t_is "${FREEZE_RC}" "1" "the survivor of a two-node fleet does not promote on its own"
t_like "$( cat "${FREEZE}" )" '^rung 2 quorum: notify' \
    "it freezes at rung 2, which is the whole of the even-N doctrine"
t_like "$( cat "${FREEZE}" )" 'FROZEN: 1 \+ 0 reachable of N=2' \
    "and it says the arithmetic rather than an adjective"
t_like "$( cat "${FREEZE}" )" 'seance promote alpha --force=quorum' \
    "and names the command that continues, which is the only way past it"
t_like "$( tail -1 "${FREEZE}" )" '^promote: stopped at rung 2 quorum' \
    "the last line is the verdict, as every verb's is"

# What did NOT happen, read from the survivor's state rather than from the exit
# code: a freeze that had fenced, mounted or registered anything would be a
# freeze in name only.
t_unlike "$( cat "${FREEZE}" )" '^rung 4 fence' \
    "the ladder never reached the fence rung, so nothing was fenced"
t_unlike "$( cat "${FREEZE}" )" '^rung 3 probes' \
    "nor even the death probes: rung 2 is where it stopped"

t_is "$( node_seance bravo placement | awk -F "${TAB}" '$1 == "placement" { print $2 }' )" \
    "" "bravo claims nothing"
t_rc 1 "and nothing was written to its succession log" \
    -- cluster_exec bravo test -s /var/db/seance/succession.log
t_rc 1 "and web01 is not registered on bravo" \
    -- cluster_exec bravo sh -c \
    "awk -F'\t' '\$1 == \"web01\"' /var/db/seance-pseudo/guests.tsv | grep ."
t_is "$( nz bravo get -H -o value mountpoint "${WEB_ON_BRAVO}" )" "none" \
    "and the replica is still hidden: a frozen ladder mounts nothing"

# ---------------------------------------------------------------------------
# THE FORCE
#
# --force=quorum skips exactly the rung it names. The fence is NOT skipped --
# D-68: what a force overrides is a thing that could not be confirmed, never
# the confirming itself -- so the driver runs, the corpse is verified off, and
# the evidence recorded is the fence's and not the operator's.
# ---------------------------------------------------------------------------

FORCED=$( t_tmpdir )/forced.out
node_seance bravo promote alpha --force=quorum > "${FORCED}" 2>&1
FORCED_RC=$?

t_is "${FORCED_RC}" "0" "with --force=quorum the promotion completes"
t_like "$( cat "${FORCED}" )" '^rung 2 quorum: forced' \
    "rung 2 says it was forced, and by whom"
t_like "$( cat "${FORCED}" )" '^rung 4 fence: pass' \
    "rung 4 still RAN: forcing the arithmetic does not skip the fencing"
t_like "$( cat "${FORCED}" )" 'fence_jail off alpha verified' \
    "and the driver verified the corpse in its own words"
t_like "$( cat "${FORCED}" )" '^promote: 1 of 1 guest\(s\) promoted from alpha' \
    "and the verdict line counts the estate"

SUCCESSION=$( cluster_exec bravo cat /var/db/seance/succession.log < /dev/null )
t_like "${SUCCESSION}" "^web01${TAB}alpha${TAB}bravo${TAB}[0-9]{8}T[0-9]{6}Z${TAB}fence:jail\$" \
    "the record's evidence is the FENCE, not the operator: what was forced was the arithmetic"

t_is "$( nz bravo get -H -o value mounted "${WEB_ON_BRAVO}" )" "yes" \
    "the replica is mounted in place"
t_stdout_is "web01-n2" "and it carries the data that was on alpha" \
    -- cluster_exec bravo cat /seance/web01/marker
t_is "$( node_seance bravo placement | awk -F "${TAB}" '$1 == "placement" { print $2 }' )" \
    "web01" "and bravo now claims it"

t_done
