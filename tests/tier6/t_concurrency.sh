#!/bin/sh
# Tier 6, stage 'concurrency' -- two heirs told about one death at the same
# instant, and exactly one of them acts.
#
# alpha loses power. Both of its heirs are armed and both are told, at the same
# moment, through the path devd would use. TWO INDEPENDENT MECHANISMS have to
# hold for exactly one of them to act, and this stage exercises both:
#
#   the NETWORK's answer -- CARP hands alpha's vhid to the first heir, because
#   the advskews are the succession map. The second heir never becomes MASTER
#   for it, so its rung 1 finds no transition to act on and stops. This is M3's
#   own mechanism and it decides before the ladder is even walked.
#
#   the LADDER's answer -- a promotion run afterwards, by hand, on the node that
#   stood down: the claim check asks the living what they are hosting and finds
#   that the guest is already somewhere. This is what would still hold if CARP
#   were lying, and it is the one the operator meets.
#
# EXACTLY ONE IS COUNTED FROM THE RESOURCE, not from the responses: every
# node's placement record is read at the end and the guests are counted, which
# is the only form of this assertion that cannot be satisfied by two commands
# that happened to finish in a convenient order.
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

stage_begin concurrency

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/fence.subr
. "${T_ROOT}/tests/cluster/lib/fence.subr"

ESTATE_CARP=1
ESTATE_AUTO=1
ESTATE_ARM_BRAVO=alpha
ESTATE_ARM_CHARLIE=alpha

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/estate.subr
. "${T_ROOT}/tests/cluster/lib/estate.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the concurrency stage builds jails and ZFS datasets; it needs root"
    echo "t_concurrency: must run as root" >&2
    exit 2
fi

t_plan 24

TAB=$( printf '\t.' )
TAB=${TAB%.}

estate_up || { t_diag "estate_up failed"; t_done; }
estate_carp_up || { t_diag "estate_carp_up failed"; t_done; }

t_rc 0 "a replication tick, so BOTH heirs hold alpha's estate" -- estate_replicate

WEB_ON_BRAVO=$( estate_replica_root bravo alpha web01 )
WEB_ON_CHARLIE=$( estate_replica_root charlie alpha web01 )
t_rc 0 "web01 has a replica on bravo" -- nz bravo list -H -o name "${WEB_ON_BRAVO}"
t_rc 0 "and on charlie, so either could in principle promote it" \
    -- nz charlie list -H -o name "${WEB_ON_CHARLIE}"

t_rc 0 "both heirs start BACKUP for alpha's vhid" \
    -- estate_carp_wait bravo 1 BACKUP 45
t_rc 0 "charlie too" -- estate_carp_wait charlie 1 BACKUP 45

# ---------------------------------------------------------------------------
# alpha loses power
# ---------------------------------------------------------------------------

cluster_stop alpha || t_diag "cluster_stop alpha failed"
t_rc 1 "alpha's jail is gone from the guest host's jls" \
    -- jls -d -j "$( cluster_jail_name alpha )" jid

# ---------------------------------------------------------------------------
# The network decides first
# ---------------------------------------------------------------------------

t_rc 0 "CARP hands alpha's vhid to bravo, its FIRST heir (advskew 100)" \
    -- estate_carp_wait bravo 1 MASTER 45
t_is "$( estate_carp_state charlie 1 )" "BACKUP" \
    "and charlie, the second heir at advskew 200, is still BACKUP for it"

# ---------------------------------------------------------------------------
# Both are told, at the same instant, through the path devd uses
# ---------------------------------------------------------------------------

BRAVO_EV=$( t_tmpdir )/bravo.event
CHARLIE_EV=$( t_tmpdir )/charlie.event

node_seance charlie promote-event "1@$( estate_carp_if charlie )" \
    > "${CHARLIE_EV}" 2>&1 &
CHARLIE_PID=$!
node_seance bravo promote-event "1@$( estate_carp_if bravo )" \
    > "${BRAVO_EV}" 2>&1
BRAVO_RC=$?
wait "${CHARLIE_PID}"
CHARLIE_RC=$?

t_is "${BRAVO_RC}" "0" "bravo's promote-event exits 0"
t_is "${CHARLIE_RC}" "0" "and charlie's, because devd waits for both"
t_like "$( cat "${BRAVO_EV}" )" 'running detached' \
    "bravo detached a promotion"
t_like "$( cat "${CHARLIE_EV}" )" 'running detached' \
    "and so did charlie: promote-event does not second-guess the ladder"

i=0
while [ "${i}" -lt 240 ]; do
    [ -n "$( node_seance bravo placement |
        awk -F "${TAB}" '$1 == "placement" && $2 == "web01" { print $2 }' )" ] && break
    i=$(( i + 1 ))
    sleep 1
done

# ---------------------------------------------------------------------------
# Exactly one acted, per guest, read from the resource
# ---------------------------------------------------------------------------

for g in web01 db01; do
    CLAIMS=""
    for n in bravo charlie; do
        [ -n "$( node_seance "${n}" placement |
            awk -F "${TAB}" -v g="${g}" '$1 == "placement" && $2 == g { print $2 }' )" ] &&
            CLAIMS="${CLAIMS} ${n}"
    done
    t_is "${CLAIMS}" " bravo" "${g}: exactly one node claims it, and it is the first heir"
done

t_rc 1 "charlie never registered web01" \
    -- cluster_exec charlie sh -c \
    "awk -F'\t' '\$1 == \"web01\"' /var/db/seance-pseudo/guests.tsv | grep ."
t_rc 1 "and charlie wrote no succession record" \
    -- cluster_exec charlie test -s /var/db/seance/succession.log

# ---------------------------------------------------------------------------
# Why charlie stood down: the network had already decided
# ---------------------------------------------------------------------------

CHARLIE_AUTO=$( t_tmpdir )/charlie.auto
node_seance charlie promote alpha --auto > "${CHARLIE_AUTO}" 2>&1
CHARLIE_AUTO_RC=$?

t_is "${CHARLIE_AUTO_RC}" "1" "charlie's automatic promotion stops"
t_like "$( cat "${CHARLIE_AUTO}" )" '^rung 1 debounce: abort — TRANSIENT MASTER' \
    "at rung 1: it is not MASTER for alpha's vhid and never was"
t_like "$( cat "${CHARLIE_AUTO}" )" '^promote: stopped at rung 1 debounce' \
    "and the verdict line says so"

# ---------------------------------------------------------------------------
# And the answer that does not depend on CARP at all
#
# A promotion charlie is told to run BY HAND walks every rung: quorum forms,
# alpha answers nothing, the fence confirms it is off -- and then rung 5 stands
# charlie down per guest, because bravo is the first heir and bravo is
# reachable. That is `pol_am_i_actor`, and it is evaluated BEFORE the claim
# check, so the claim check is not what an operator meets here; it is the layer
# behind it, for the case where the actor rule says this node IS the actor and
# somebody has the guest anyway. tests/tier4/ladder.tsv's `claim-by-peer` row is
# where that one is pinned, because it cannot be reached in this fixture while
# the first heir is answering.
#
# What matters at this tier is the outcome and where it came from: charlie
# walked the whole ladder, fenced nothing new, and claimed nothing.
# ---------------------------------------------------------------------------

CHARLIE_MAN=$( t_tmpdir )/charlie.manual
node_seance charlie promote alpha > "${CHARLIE_MAN}" 2>&1
CHARLIE_MAN_RC=$?

t_is "${CHARLIE_MAN_RC}" "0" \
    "a promotion charlie is told to run by hand exits 0 -- standing down is not a failure"
t_like "$( cat "${CHARLIE_MAN}" )" \
    '^  web01: stand-down -- succession is bravo charlie, and this node is not the actor for it' \
    "and stands down per guest, naming the succession it read the answer from"
t_like "$( cat "${CHARLIE_MAN}" )" \
    '^  db01: stand-down -- succession is bravo charlie' \
    "for every guest of the estate, not just the first"
t_like "$( cat "${CHARLIE_MAN}" )" \
    '^promote: 0 of 2 guest\(s\) promoted from alpha' \
    "and the verdict line counts what it did not do"

t_is "$( node_seance charlie placement | awk -F "${TAB}" '$1 == "placement" { print $2 }' )" \
    "" "so charlie still claims nothing, after being asked twice"

t_done
