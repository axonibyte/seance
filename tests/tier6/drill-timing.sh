#!/bin/sh
# Tier 6, OPT-IN -- drill-node's timing table, measured.
#
#   env REAPER_STATE=/tank/state sh tests/tier6/drill-timing.sh
#
# NOT NAMED t_*.sh ON PURPOSE: tests/run.sh collects tests/tier<N>/t_*.sh, and
# this file spends the shipped default debounce (45 s) on purpose, which no
# stage should. It is what fills in docs/DRILLS.md's `drill-node` timing table
# with numbers instead of estimates.
#
# WHAT IT MEASURES, and against what. drill-node is a tier-8 drill: real
# hardware, real power cut, real devd. Shape A cannot be that (devd(8) is
# KEYWORD: nojail and does not run in a vnet jail -- D-128), and it can be
# every other link in the chain, with the same code and the same
# configuration:
#
#   T0  the victim stops answering        (cluster_stop: the jail goes away)
#   T1  the heir holds the victim's vhid   (CARP elects, for real)
#   T2  promote-event has returned         (devd's event loop is released)
#   T3  the ladder's debounce passed       (the shipped 45 s, not a fixture's 5)
#   T4  the fence confirmed the victim off
#   T5  the estate is promoted             (mounted, registered, started)
#
# What it cannot measure is T1's real length on hardware (a kernel's CARP
# timers on a physical segment), the devd delivery T1->T2 (no devd here: this
# invokes `promote-event` itself, exactly as the tier-6 stages do), and T5->T6,
# a guest booting to a service that answers. Each is named in DRILLS.md beside
# the number, because a measurement whose limits are not stated gets quoted
# without them.
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
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/fence.subr
. "${T_ROOT}/tests/cluster/lib/fence.subr"

# The shipped default debounce, because the number this file produces is quoted
# against a five-minute target and 40 seconds of that target is this setting.
ESTATE_DEBOUNCE=${ESTATE_DEBOUNCE:-45}
ESTATE_CARP=1
ESTATE_AUTO=1
ESTATE_ARM_BRAVO=alpha

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/estate.subr
. "${T_ROOT}/tests/cluster/lib/estate.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    echo "drill-timing: builds jails and ZFS datasets; it needs root" >&2
    exit 2
fi

TAB=$( printf '\t.' )
TAB=${TAB%.}

t_plan 10

estate_up || { t_diag "estate_up failed"; t_done; }
estate_carp_up || { t_diag "estate_carp_up failed"; t_done; }
estate_replicate || t_diag "the replication tick failed"

t_rc 0 "alpha holds its own vhid before the drill" \
    -- estate_carp_wait alpha 1 MASTER 45
t_rc 0 "and bravo is BACKUP for it, as its heir" \
    -- estate_carp_wait bravo 1 BACKUP 45

# ---------------------------------------------------------------------------
# T0 -- the victim stops answering
# ---------------------------------------------------------------------------

T0=$( date +%s )
cluster_stop alpha || t_diag "cluster_stop alpha failed"

# T1 -- the heir holds the victim's vhid
estate_carp_wait bravo 1 MASTER 120
CARP_RC=$?
T1=$( date +%s )
t_rc 0 "the heir became CARP MASTER for the victim's vhid ($(( T1 - T0 ))s)" \
    -- test "${CARP_RC}" -eq 0

# ---------------------------------------------------------------------------
# T2 -- promote-event returns, which is when devd's event loop is released
# ---------------------------------------------------------------------------

EVENT=$( t_tmpdir )/event.out
node_seance bravo promote-event "1@$( estate_carp_if bravo )" > "${EVENT}" 2>&1
EVENT_RC=$?
T2=$( date +%s )

t_is "${EVENT_RC}" "0" "promote-event exits 0, because devd waits for it"
t_rc 0 "and it returned in $(( T2 - T1 ))s, inside the second it was called in" \
    -- test "$(( T2 - T1 ))" -le 2
t_like "$( cat "${EVENT}" )" 'running detached' \
    "having detached the promotion rather than running it in devd's event loop"

# ---------------------------------------------------------------------------
# T5 -- the estate is promoted. Read from the disks, not from an exit code.
# ---------------------------------------------------------------------------

i=0
while [ "${i}" -lt 300 ]; do
    [ -n "$( node_seance bravo placement |
        awk -F "${TAB}" '$1 == "placement" && $2 == "web01" { print $2 }' )" ] && break
    i=$(( i + 1 ))
    sleep 1
done
T5=$( date +%s )

t_like "$( node_seance bravo placement )" "^placement${TAB}web01${TAB}alpha\$" \
    "the heir ends up hosting the victim's guest"
t_like "$( cluster_exec bravo cat /var/db/seance/succession.log < /dev/null )" \
    "fence:jail\$" \
    "with a fence as the evidence, because nobody typed anything"

# The rung timestamps, from the detached run's own syslog inside the node.
LOG=$( t_tmpdir )/messages
cluster_exec bravo cat /var/log/messages < /dev/null > "${LOG}" 2>/dev/null || :

t_rc 0 "the detached ladder logged its rungs to syslog, where the drill reads them" \
    -- grep -q 'rung 4 fence' "${LOG}"

TOTAL=$(( T5 - T0 ))
t_rc 0 "T0->T5, victim gone to estate running: ${TOTAL}s (target: under 300)" \
    -- test "${TOTAL}" -lt 300

t_diag "MEASURED, shape A, debounce=${ESTATE_DEBOUNCE}:"
t_diag "  T0->T1 victim gone to heir MASTER for its vhid: $(( T1 - T0 ))s"
t_diag "  T1->T2 promote-event (devd's event loop released): $(( T2 - T1 ))s"
t_diag "  T2->T5 debounce, quorum, probes, fence, mount, register, start: $(( T5 - T2 ))s"
t_diag "  T0->T5 TOTAL: ${TOTAL}s"

t_done
