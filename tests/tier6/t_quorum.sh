#!/bin/sh
# Tier 6, stage 'quorum' -- an isolated node is not a dead node, and it must
# not act.
#
# alpha is ALIVE and UNREACHABLE: its jail keeps running, its guests keep
# running, and its host-side epair is off the bridge. From alpha's own point of
# view every peer has died at once; from bravo's, alpha has. Both of them see
# themselves become CARP MASTER for a vhid that is not theirs, and exactly one
# of them may act on it.
#
#   bravo   1 + 1 reachable of N=3 is a majority -> acts. alpha answers neither
#           ping nor ssh (it cannot), so rung 3 passes; rung 4 fences it
#           through the driver and the guest host really does stop the jail.
#   alpha   1 + 0 reachable of N=3 is not a majority -> FREEZES at rung 2,
#           notifies, and touches nothing. This is the rule that is the whole
#           difference between an outage and a split brain.
#
# ALPHA IS ASKED FIRST, and that is deliberate rather than incidental: bravo's
# rung 4 stops alpha's jail, so a concurrent alpha would be measured or killed
# depending on which finished first. Asking it before it is fenced asserts the
# same property -- an isolated node freezes -- without a race in the fixture.
#
# EXACTLY ONE ACTOR IS READ FROM CLUSTER STATE at the end, from every node's
# own placement records, and not from the exit codes of the two commands.
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

stage_begin quorum

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

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/estate.subr
. "${T_ROOT}/tests/cluster/lib/estate.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the quorum stage builds jails and ZFS datasets; it needs root"
    echo "t_quorum: must run as root" >&2
    exit 2
fi

t_plan 25

TAB=$( printf '\t.' )
TAB=${TAB%.}

estate_up || { t_diag "estate_up failed"; t_done; }
estate_carp_up || { t_diag "estate_carp_up failed"; t_done; }

t_rc 0 "a replication tick, so the heirs hold alpha's estate" -- estate_replicate

t_rc 0 "alpha starts out MASTER for its own vhid" \
    -- estate_carp_wait alpha 1 MASTER 45
t_rc 0 "and bravo BACKUP for it" -- estate_carp_wait bravo 1 BACKUP 45

# ---------------------------------------------------------------------------
# alpha is isolated: alive, and unreachable
# ---------------------------------------------------------------------------

cluster_isolate alpha || t_diag "cluster_isolate alpha failed"

t_rc 0 "with alpha off the bridge, bravo becomes MASTER for alpha's vhid" \
    -- estate_carp_wait bravo 1 MASTER 45
t_rc 0 "and alpha, hearing nobody, becomes MASTER for bravo's vhid too" \
    -- estate_carp_wait alpha 2 MASTER 45

t_rc 0 "alpha's jail is still running -- it was isolated, not stopped" \
    -- jls -d -j "$( cluster_jail_name alpha )" jid

# ---------------------------------------------------------------------------
# alpha, isolated, tries to succeed bravo -- and freezes
# ---------------------------------------------------------------------------

ALPHA_OUT=$( t_tmpdir )/alpha.out
node_seance alpha promote bravo --auto > "${ALPHA_OUT}" 2>&1
ALPHA_RC=$?

t_is "${ALPHA_RC}" "1" "the isolated node's automatic promotion stops"
t_like "$( cat "${ALPHA_OUT}" )" '^rung 0 arming: pass' \
    "it was armed for bravo, so the freeze is not a disarmed node's"
t_like "$( cat "${ALPHA_OUT}" )" '^rung 1 debounce: pass' \
    "and it really is MASTER for bravo's vhid, so rung 1 passed"
t_like "$( cat "${ALPHA_OUT}" )" '^rung 2 quorum: notify — FROZEN: 1 \+ 0 reachable of N=3' \
    "and rung 2 is what stopped it: a node that can reach nobody must assume it is the isolated one"
t_like "$( cat "${ALPHA_OUT}" )" '^promote: stopped at rung 2 quorum' \
    "the verdict line names the rung"

t_is "$( node_seance alpha placement | awk -F "${TAB}" '$1 == "placement" { print $2 }' )" \
    "" "the isolated node claims nothing"
t_rc 1 "and wrote no succession record at all" \
    -- cluster_exec alpha test -s /var/db/seance/succession.log

# It also fenced nothing, which matters more than the freeze: rung 2 is before
# rung 4, and an isolated node that fenced its way to a quorum would be the
# accident this rung exists to prevent.
t_rc 0 "and bravo's jail is untouched: the frozen node fenced nobody" \
    -- jls -d -j "$( cluster_jail_name bravo )" jid

# ---------------------------------------------------------------------------
# bravo, connected, succeeds alpha -- through the devd path
# ---------------------------------------------------------------------------

EVENT=$( t_tmpdir )/event.out
node_seance bravo promote-event "1@$( estate_carp_if bravo )" > "${EVENT}" 2>&1
EVENT_RC=$?

t_is "${EVENT_RC}" "0" "promote-event exits 0, because devd waits for it"
t_like "$( cat "${EVENT}" )" '^promote-event: CARP MASTER for alpha \(vhid 1 on ' \
    "it named the node the vhid stands for"
t_like "$( cat "${EVENT}" )" 'running detached' \
    "and detached the promotion rather than running it inside devd's event loop"

# The promotion is now a separate process; what it did is read from the disks.
WEB_ON_BRAVO=$( estate_replica_root bravo alpha web01 )
i=0
while [ "${i}" -lt 180 ]; do
    [ -n "$( node_seance bravo placement |
        awk -F "${TAB}" '$1 == "placement" && $2 == "web01" { print $2 }' )" ] && break
    i=$(( i + 1 ))
    sleep 1
done

t_like "$( node_seance bravo placement )" "^placement${TAB}web01${TAB}alpha\$" \
    "bravo ends up hosting web01 away from its home"
t_like "$( cluster_exec bravo cat /var/db/seance/succession.log < /dev/null )" \
    "^web01${TAB}alpha${TAB}bravo${TAB}[0-9]{8}T[0-9]{6}Z${TAB}fence:jail\$" \
    "with the FENCE as evidence, not a force: nobody typed anything"

t_rc 1 "and alpha's jail is gone: the fence was real" \
    -- jls -d -j "$( cluster_jail_name alpha )" jid

t_is "$( nz bravo get -H -o value mounted "${WEB_ON_BRAVO}" )" "yes" \
    "the replica is mounted here"
t_stdout_is "web01-v1" "and carries the data that was on the source" \
    -- cluster_exec bravo cat /seance/web01/marker

# ---------------------------------------------------------------------------
# Exactly one actor, counted from the resource and not from the responses
# ---------------------------------------------------------------------------

CLAIMS=0
for n in bravo charlie; do
    [ -n "$( node_seance "${n}" placement |
        awk -F "${TAB}" '$1 == "placement" && $2 == "web01" { print $2 }' )" ] &&
        CLAIMS=$(( CLAIMS + 1 ))
done
t_is "${CLAIMS}" "1" "exactly one LIVING node claims web01"

t_is "$( node_seance charlie placement | awk -F "${TAB}" '$1 == "placement" { print $2 }' )" \
    "" "and it is not charlie, which claims nothing"
t_rc 1 "charlie never registered web01 either" \
    -- cluster_exec charlie sh -c \
    "awk -F'\t' '\$1 == \"web01\"' /var/db/seance-pseudo/guests.tsv | grep ."

t_done
