#!/bin/sh
# Tier 6, stage 'carp' -- real CARP on a real pseudo-cluster (D-27).
#
# Three vnet jails on one bridge, three vhids, and the advskews that ARE the
# succession map (design §6). What is asserted is that the map seance renders
# and the map the network arrives at are the same map: each node MASTER for its
# own identity, BACKUP for the identities it may inherit, and `verify` able to
# say so afterwards without being told.
#
# THE TEST APPLIES; SEANCE NEVER DOES. Every line applied to an interface here
# came out of `seance verify --render carp` on that node -- nothing in
# tests/cluster/lib/estate.subr writes an ifconfig argument of its own. A
# rendering that could not be applied is a rendering that is wrong, and this is
# the only tier that can find that out.
#
# WHAT SHAPE A CANNOT PROVE, said here rather than left to be discovered:
# devd(8) is KEYWORD: nojail and does not run in a vnet jail, so the rules are
# asserted to be rendered, installed and recognised, and the FIRING of one is
# tier 8's -- docs/DRILLS.md drill-node, steps 6 and T2.
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

stage_begin carp

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/fence.subr
. "${T_ROOT}/tests/cluster/lib/fence.subr"

ESTATE_CARP=1
ESTATE_AUTO=1
ESTATE_ARM_ALPHA=bravo
ESTATE_ARM_BRAVO=alpha
ESTATE_ARM_CHARLIE=alpha

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/estate.subr
. "${T_ROOT}/tests/cluster/lib/estate.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the carp stage builds jails and configures interfaces; it needs root"
    echo "t_carp: must run as root" >&2
    exit 2
fi

t_plan 39

estate_up || { t_diag "estate_up failed"; t_done; }

t_rc 0 "the CARP-configured fleet validates on alpha" \
    -- node_seance alpha config --check
t_rc 0 "and on bravo, which is the same file" \
    -- node_seance bravo config --check

estate_carp_up || { t_diag "estate_carp_up failed"; t_done; }

# The crontab fragment, so that the one verify(1) below is about CARP rather
# than about a replication schedule nobody installed.
t_rc 0 "a replication tick, so the standby parents exist to be checked" \
    -- estate_replicate
for n in alpha bravo charlie; do
    node_seance "${n}" verify --render cron \
        > "$( cluster_root "${n}" )/usr/local/etc/cron.d/seance"
done

# ---------------------------------------------------------------------------
# The rendering
# ---------------------------------------------------------------------------

RENDER_A=$( node_seance alpha verify --render carp )
RENDER_B=$( node_seance bravo verify --render carp )

t_is "${RENDER_A}" "$( node_seance alpha verify --render carp )" \
    "verify --render carp is byte-stable across two runs"
t_isnt "${RENDER_A}" "${RENDER_B}" \
    "and it differs per node, because the advskews are that node's place in the map"

ALPHA_IF=$( estate_carp_if alpha )
BRAVO_IF=$( estate_carp_if bravo )

# The FIRST rendered assignment, not alias0: the verb observes the indices a
# node's rc.conf already occupies and renders after them (D-179), and this
# render runs AFTER the cluster build installed the first three -- so the base
# has legitimately moved. What is pinned is the ordering (the node's own vhid
# first, carp_participation's contract), not the absolute index.
t_like "$( printf '%s\n' "${RENDER_A}" | grep '^ifconfig_' | head -1 )" \
    "^ifconfig_${ALPHA_IF}_alias[0-9]+=\"inet $( estate_vhid_ip alpha ) vhid 1 advskew 0 " \
    "alpha renders its own vhid first, at advskew 0"
t_like "${RENDER_A}" "vhid 2 advskew 200 " \
    "bravo's vhid at 200, because alpha is bravo's SECOND heir"
t_like "${RENDER_A}" "vhid 3 advskew 100 " \
    "and charlie's at 100, because alpha is charlie's heir"
t_like "$( printf '%s\n' "${RENDER_B}" | grep '^ifconfig_' | head -1 )" \
    "^ifconfig_${BRAVO_IF}_alias[0-9]+=\"inet $( estate_vhid_ip bravo ) vhid 2 advskew 0 " \
    "bravo renders its own vhid first, at advskew 0, on ITS OWN interface"
t_like "${RENDER_B}" "vhid 1 advskew 100 " \
    "and alpha's at 100, because bravo is alpha's heir"

# ---------------------------------------------------------------------------
# The election: the map the network arrives at
# ---------------------------------------------------------------------------

for pair in "alpha 1" "bravo 2" "charlie 3"; do
    # shellcheck disable=SC2086
    #   Deliberate word splitting: each element is a node name and a vhid,
    #   written here, neither of which can contain whitespace or a glob.
    set -- ${pair}
    t_rc 0 "$1 is MASTER for vhid $2, which is its own identity" \
        -- estate_carp_wait "$1" "$2" MASTER 45
done

t_rc 0 "bravo is BACKUP for alpha's vhid, as its heir" \
    -- estate_carp_wait bravo 1 BACKUP 45
t_rc 0 "charlie is BACKUP for alpha's vhid too, as its second heir" \
    -- estate_carp_wait charlie 1 BACKUP 45
t_rc 0 "alpha is BACKUP for bravo's vhid" \
    -- estate_carp_wait alpha 2 BACKUP 45
t_rc 0 "and for charlie's" -- estate_carp_wait alpha 3 BACKUP 45

# The one that would be easy to get backwards: a node must NOT be master for
# an identity that is not its own while its owner is alive.
t_is "$( estate_carp_state bravo 1 )" "BACKUP" \
    "and nothing is MASTER for an identity whose owner is alive"

# ---------------------------------------------------------------------------
# The sysctls the model depends on
# ---------------------------------------------------------------------------

t_stdout_is "1" "net.inet.carp.preempt is 1 inside the node's own vnet" \
    -- node_sh alpha 'sysctl -n net.inet.carp.preempt'
t_stdout_is "1" "and net.inet.carp.allow" \
    -- node_sh alpha 'sysctl -n net.inet.carp.allow'

# ---------------------------------------------------------------------------
# verify: what seance says about what the test just applied
# ---------------------------------------------------------------------------

VERIFY=$( t_tmpdir )/verify.alpha
node_seance alpha verify > "${VERIFY}" 2>&1
VERIFY_RC=$?

t_like "$( cat "${VERIFY}" )" '^PASS carp: ifconfig_[a-z0-9_]+_alias[0-9]+ carries vhid 1 \(owner of alpha\)' \
    "verify finds alpha's own vhid in its rc.conf, at whatever index"
t_like "$( cat "${VERIFY}" )" '^PASS carp: vhid 1 is MASTER here, which is this node.s own identity' \
    "and MASTER on the interface"
t_like "$( cat "${VERIFY}" )" '^PASS carp: vhid 3 is BACKUP here, as charlie.s heir' \
    "and BACKUP for the identity it may inherit"
t_like "$( cat "${VERIFY}" )" '^PASS carp: net\.inet\.carp\.preempt is 1' \
    "and names the sysctl the map depends on"
t_like "$( cat "${VERIFY}" )" '^PASS carp: rc\.conf kld_list loads carp at boot' \
    "and that the module is arranged to load"
t_like "$( cat "${VERIFY}" )" '^PASS devd: .* runs \[' \
    "verify finds the devd action it rendered"
t_like "$( cat "${VERIFY}" )" '^PASS devd: .* has a rule for vhid 3 \(charlie\)' \
    "and a rule per vhid this node may inherit"
t_unlike "$( cat "${VERIFY}" )" '^PASS devd: .* has a rule for vhid 1 \(alpha\)' \
    "and none for its OWN vhid, which it does not inherit from anybody"

t_is "$( awk '/^FAIL /' "${VERIFY}" | wc -l | tr -d ' ' )" "0" \
    "verify reports no FAIL of any kind on a node the rendering was applied to"

# devd cannot run in a vnet jail (KEYWORD: nojail), so this is the one warning
# shape A must have, and it is asserted rather than tolerated: a stage that
# accepted "some warnings" would accept the next one too.
t_is "$( awk '/^WARN /' "${VERIFY}" | wc -l | tr -d ' ' )" "1" \
    "exactly one warning"
t_like "$( awk '/^WARN /' "${VERIFY}" )" '^WARN devd: service devd status does not report it running' \
    "and it is devd, which is KEYWORD: nojail and cannot run in a vnet jail"
t_is "${VERIFY_RC}" "1" \
    "so verify exits 1 -- one warning is a difference between the rendering and reality"

t_like "$( cat "${VERIFY}" )" '^PASS gate: /usr/local/etc/rc.d/seance_gate is installed and seance_gate_enable is YES' \
    "verify sees the boot gate installed and enabled -- the check whose absence looked like health (D-183)"
# On BRAVO, which is where alpha's replicas actually live: alpha holds nobody
# else's estate in this world, and a check that reported on an empty standby
# tree would be a green line about datasets that are not there.
VERIFY_B=$( t_tmpdir )/verify.bravo
node_seance bravo verify > "${VERIFY_B}" 2>&1
t_like "$( cat "${VERIFY_B}" )" '^PASS replica: [1-9][0-9]* replica\(s\) of alpha record the guest they belong to' \
    "and the node HOLDING alpha's replicas can say which guest each one belongs to"

t_like "$( cat "${VERIFY}" )" '^verify: renderings available: cron, carp, devd' \
    "and the summary names every subject verify can render"

# ---------------------------------------------------------------------------
# The rendering is what was installed, on every node
# ---------------------------------------------------------------------------

for n in alpha bravo charlie; do
    t_is "$( node_seance "${n}" verify | awk '/^FAIL /' | wc -l | tr -d ' ' )" "0" \
        "${n}: no FAIL either"
done

# The password went into rc.conf, which is why the rendering says to chmod it.
t_stdout_is "600" "the rc.conf carrying the CARP password is mode 0600" \
    -- node_sh alpha 'stat -f %Lp /etc/rc.conf'

t_done
