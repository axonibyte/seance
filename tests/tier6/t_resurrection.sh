#!/bin/sh
# Tier 6, stage 'resurrection' -- the boot gate, both halves (TESTING.md §7).
#
# The gate is what stands between a node that has been powered back on by a
# well-meaning human and the split brain that would follow. TESTING.md names
# two halves and this stage runs both:
#
#   1. a returning node whose guest is CLAIMED by a survivor must start none of
#      it and notify;
#   2. a returning node that can reach NOBODY must start nothing at all and
#      notify -- because a node that reaches nobody must assume it is the
#      isolated one, and the alternative is starting guests that are already
#      running somewhere else.
#
# And the third thing, which is what makes the gate a gate rather than a lock:
# once the claim is gone -- after a failback -- the estate is allowed up again.
#
# WHAT IS ASSERTED IS THE STATE, not the exit code: the guests' own records on
# the returning node, and the fact that the platform's start path refuses a
# held guest. `adapter_guest_start` on a held guest returning non-zero is the
# pseudo-cluster's stand-in for CBSD's "Jail in slave mode" (D-21); the real
# thing is a shape-B assertion and is named as such in tests/tier5/README.
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

stage_begin resurrection

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
    t_diag "the resurrection stage builds jails and ZFS datasets; it needs root"
    echo "t_resurrection: must run as root" >&2
    exit 2
fi

t_plan 25

TAB=$( printf '\t.' )
TAB=${TAB%.}

estate_up || { t_diag "estate_up failed"; t_done; }

# held <node> <guest>  -- the pseudo-adapter's own record of the hold.
held()
{
    cluster_exec "$1" env "SEANCE_ADAPTER=${ESTATE_ADAPTER}" sh -c \
        ". ${ESTATE_ADAPTER}; adapter_guest_held $2" < /dev/null
}

running()
{
    cluster_exec "$1" env "SEANCE_ADAPTER=${ESTATE_ADAPTER}" sh -c \
        ". ${ESTATE_ADAPTER}; adapter_guest_running $2" < /dev/null
}

# ---------------------------------------------------------------------------
# Half one: a survivor claims a returning node's guest
# ---------------------------------------------------------------------------

t_rc 0 "a replication tick on alpha" -- estate_replicate

cluster_stop alpha || t_diag "cluster_stop alpha failed"
t_rc 0 "alpha's estate is promoted onto bravo" -- node_seance bravo promote alpha

estate_reboot alpha || t_diag "estate_reboot alpha failed"

# Nothing has gated yet: this is the state a node is in the instant it boots.
t_is "$( held alpha web01 )" "0" \
    "the instant it is back, alpha's own record of web01 is unheld"

GATE1=$( t_tmpdir )/gate1.out
node_seance alpha gate > "${GATE1}" 2>&1
GATE1_RC=$?

t_is "${GATE1_RC}" "1" "the gate does not exit 0 when it has withheld something"
t_like "$( cat "${GATE1}" )" '^gate: HELD web01 -- bravo claims it$' \
    "it names the guest and the peer that claims it"
t_like "$( cat "${GATE1}" )" '^gate: HELD db01 -- bravo claims it$' \
    "and it does so for every claimed guest, not the first one"
t_like "$( cat "${GATE1}" )" '^  undo: seance gate --release web01' \
    "and prints the undo beside the hold"

t_is "$( held alpha web01 )" "1" "web01 is now HELD on alpha"
t_is "$( held alpha db01 )" "1" "and so is db01"

# The hold is a veto, not a note: the start path refuses it.
t_rc 1 "the platform's start path refuses a held guest" \
    -- cluster_exec alpha env "SEANCE_ADAPTER=${ESTATE_ADAPTER}" sh -c \
    ". ${ESTATE_ADAPTER}; adapter_guest_start web01"
t_is "$( running alpha web01 )" "0" "and web01 is still not running on alpha"

# Releasing is refused while the claim stands.
REL=$( t_tmpdir )/release.out
node_seance alpha gate --release web01 > "${REL}" 2>&1
REL_RC=$?
t_is "${REL_RC}" "1" "gate --release is refused while bravo still claims the guest"
t_like "$( cat "${REL}" )" '^gate: REFUSED web01 -- bravo still claims it$' \
    "and says which peer"
t_is "$( held alpha web01 )" "1" "and web01 stays held"

# ---------------------------------------------------------------------------
# Half two: a returning node that can reach nobody at all
# ---------------------------------------------------------------------------

# charlie hosts nothing of anybody's and nobody claims anything of charlie's.
# Cut it off entirely: reaching NOBODY must withhold everything regardless.
estate_guest_create charlie svc01 jail charlie || t_diag "creating svc01 failed"

t_is "$( held charlie svc01 )" "0" "svc01 starts out unheld on charlie"

cluster_isolate charlie || t_diag "cluster_isolate charlie failed"

GATE2=$( t_tmpdir )/gate2.out
node_seance charlie gate > "${GATE2}" 2>&1
GATE2_RC=$?

t_is "${GATE2_RC}" "1" "a node that reaches nobody does not exit 0"
t_like "$( cat "${GATE2}" )" '^gate: HELD svc01 -- not one peer answered$' \
    "it withholds a guest NOBODY has claimed, because nobody could be asked"
t_like "$( cat "${GATE2}" )" 'NOT ONE PEER ANSWERED' \
    "and says so in capitals"
t_is "$( held charlie svc01 )" "1" \
    "an isolated node withholds its WHOLE estate: this is the fail-safe, not a claim"

cluster_heal charlie || t_diag "cluster_heal charlie failed"

t_rc 0 "once the mesh is back and nobody claims it, svc01 can be released" \
    -- node_seance charlie gate --release svc01
t_is "$( held charlie svc01 )" "0" "and it is released"

# ---------------------------------------------------------------------------
# Half three: after a failback, the estate is allowed up again
# ---------------------------------------------------------------------------

# --discard-origin-writes because this stage is about the gate, not about the
# written@base guard: a returning node has usually written SOMETHING to its own
# copy, and refusing here would be the failback stage's assertion arriving in
# the wrong file. tests/tier6/t_failback.sh is where that guard is measured.
t_rc 0 "web01 fails back to alpha" \
    -- node_seance alpha failback web01 --discard-origin-writes

t_is "$( held alpha web01 )" "0" "failback released web01 at home"

# The gate, run again, must now leave web01 alone: nobody claims it any more.
GATE3=$( t_tmpdir )/gate3.out
node_seance alpha gate > "${GATE3}" 2>&1

t_like "$( cat "${GATE3}" )" '^gate: web01 -- no living peer claims it; left as it is$' \
    "a second gate leaves a guest nobody claims alone -- the autostart equivalent proceeds"
t_is "$( held alpha web01 )" "0" "and web01 is still not held"

t_done
