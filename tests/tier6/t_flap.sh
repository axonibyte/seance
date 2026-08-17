#!/bin/sh
# Tier 6, stage 'flap' -- a link that comes back inside the debounce window,
# and the rung that exists for exactly that.
#
# alpha's port leaves the bridge and returns a few seconds later. Nothing died.
# In between, CARP does what it is supposed to: bravo hears nothing from alpha,
# takes alpha's vhid, and devd tells bravo about it. THE TRANSITION WAS TRUE
# AND IS NO LONGER TRUE, and rung 1 is the only thing in the ladder that can
# know the difference -- it waits `debounce` seconds and asks the interface
# again.
#
# WHY BOTH ENDS ARE MASTER DURING THE SPLIT, and why that is what makes the
# heal resolve the right way round: while alpha is off the bridge it still
# hears nobody, so it stays MASTER for its own vhid; bravo also becomes MASTER
# for it. When the port comes back, both are MASTER and both hear each other,
# and sys/netinet/ip_carp.c's MASTER case demotes the one advertising less
# frequently -- which is bravo, at advskew 100, by construction. The map
# reasserts itself with no operator and no preemption sysctl involved.
#
# NOTHING MAY CHANGE. Not a placement, not a succession record, and above all
# not alpha's power: rung 1 is before rung 4, so a flap must not cost a node
# its jail.
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

stage_begin flap

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/fence.subr
. "${T_ROOT}/tests/cluster/lib/fence.subr"

ESTATE_CARP=1
ESTATE_AUTO=1
ESTATE_ARM_BRAVO=alpha

# The window this stage is about. Long enough that the heal, and CARP's own
# reconvergence after it, both land inside it -- and it is the CONFIGURED
# value, so the rung is reading the configuration rather than a constant.
ESTATE_DEBOUNCE=40

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/estate.subr
. "${T_ROOT}/tests/cluster/lib/estate.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the flap stage builds jails and ZFS datasets; it needs root"
    echo "t_flap: must run as root" >&2
    exit 2
fi

t_plan 18

TAB=$( printf '\t.' )
TAB=${TAB%.}

estate_up || { t_diag "estate_up failed"; t_done; }
estate_carp_up || { t_diag "estate_carp_up failed"; t_done; }

t_rc 0 "a replication tick, so bravo would have something to promote" \
    -- estate_replicate

t_rc 0 "alpha is MASTER for its own vhid" -- estate_carp_wait alpha 1 MASTER 45
t_rc 0 "and bravo is BACKUP for it" -- estate_carp_wait bravo 1 BACKUP 45

t_stdout_is "${ESTATE_DEBOUNCE}" "the fleet's debounce is what this stage set" \
    -- node_sh alpha "${ESTATE_BIN} config | awk '\$3 == \"debounce\" { print \$4 }'"

# ---------------------------------------------------------------------------
# The link goes
# ---------------------------------------------------------------------------

cluster_isolate alpha || t_diag "cluster_isolate alpha failed"

t_rc 0 "bravo takes alpha's vhid, exactly as it would for a death" \
    -- estate_carp_wait bravo 1 MASTER 45

# ---------------------------------------------------------------------------
# devd fires, and the link comes back while the ladder is still waiting
# ---------------------------------------------------------------------------

FLAP_OUT=$( t_tmpdir )/flap.out
node_seance bravo promote alpha --auto > "${FLAP_OUT}" 2>&1 &
FLAP_PID=$!

sleep 5
cluster_heal alpha || t_diag "cluster_heal alpha failed"

t_rc 0 "healed, alpha reclaims its own vhid" -- estate_carp_wait alpha 1 MASTER 45
t_rc 0 "and bravo goes back to BACKUP for it, well inside the debounce window" \
    -- estate_carp_wait bravo 1 BACKUP 45

wait "${FLAP_PID}"
FLAP_RC=$?

# ---------------------------------------------------------------------------
# What the ladder did with it
# ---------------------------------------------------------------------------

t_is "${FLAP_RC}" "1" "the automatic promotion stops"
t_like "$( cat "${FLAP_OUT}" )" '^rung 0 arming: pass' \
    "bravo was armed, so what stopped it is not a disarmed node"
t_like "$( cat "${FLAP_OUT}" )" '^rung 1 debounce: abort — TRANSIENT MASTER' \
    "rung 1 waited, asked the interface again, and found the transition gone"
t_like "$( cat "${FLAP_OUT}" )" "is \[BACKUP\] for vhid 1" \
    "and says what it found instead of MASTER"
t_like "$( cat "${FLAP_OUT}" )" 'the link flapped, the node did not die' \
    "in the words an operator reading a page at 03:00 needs"
t_like "$( cat "${FLAP_OUT}" )" '^promote: stopped at rung 1 debounce' \
    "the verdict line names rung 1"

# ---------------------------------------------------------------------------
# And NOTHING changed
# ---------------------------------------------------------------------------

t_rc 0 "alpha's jail is still running: rung 1 is before rung 4, so nothing fenced it" \
    -- jls -d -j "$( cluster_jail_name alpha )" jid

t_is "$( node_seance bravo placement | awk -F "${TAB}" '$1 == "placement" { print $2 }' )" \
    "" "bravo claims nothing"
t_rc 1 "and wrote no succession record" \
    -- cluster_exec bravo test -s /var/db/seance/succession.log

t_is "$( nz bravo get -H -o value mountpoint "$( estate_replica_root bravo alpha web01 )" )" \
    "none" "the replica was never mounted: the mount ceremony is rung 6"

t_stdout_is "web01-v1" "and web01 is still where it was, on alpha" \
    -- cluster_exec alpha cat /seance/web01/marker

t_done
