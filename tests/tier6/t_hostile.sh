#!/bin/sh
# Tier 6, stage 'hostile' -- the tree with somebody else in it (TESTING.md §7).
#
# Three hostile conditions, each of which has a right answer that is not
# "carry on":
#
#   1. FOREIGN SNAPSHOTS. Another tool's snapshots live in the same datasets.
#      seance must walk past them -- never destroy them, never count them as
#      lineage -- and a dataset whose ONLY snapshots are foreign is not part of
#      anybody's estate, however much it looks like a guest.
#   2. A REPLICA STAMPED IN THE FUTURE. A clock somewhere is wrong, so every
#      staleness number derived from that replica is a fiction. It is
#      force-only: a human may accept it, arithmetic may not.
#   3. A HAND-MOUNTED REPLICA. Somebody set a mountpoint on a standby dataset
#      and mounted it. seance may REPAIR that or REFUSE it, and this stage
#      asserts that it did exactly one of the two and said which -- what it may
#      not do is proceed as though the tree were clean. (DESIGN §6 invariant 4a
#      names the same either/or.)
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

stage_begin hostile

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
    t_diag "the hostile stage builds jails and ZFS datasets; it needs root"
    echo "t_hostile: must run as root" >&2
    exit 2
fi

t_plan 23

TAB=$( printf '\t.' )
TAB=${TAB%.}

estate_up || { t_diag "estate_up failed"; t_done; }

BRAVO_DS=$( cluster_dataset bravo )
ALPHA_DS=$( cluster_dataset alpha )
WEB_ON_BRAVO=$( estate_replica_root bravo alpha web01 )
DB_ON_BRAVO=$( estate_replica_root bravo alpha db01 )

t_rc 0 "a replication tick on alpha" -- estate_replicate

# ---------------------------------------------------------------------------
# 1. Foreign snapshots
# ---------------------------------------------------------------------------

nz bravo snapshot "${WEB_ON_BRAVO}@zrepl_20200101_000000_000" ||
    t_diag "planting a foreign snapshot on the replica failed"
nz alpha snapshot "${ALPHA_DS}/web01@backup-before-the-upgrade" ||
    t_diag "planting a foreign snapshot on the source failed"

node_sh alpha 'echo web01-v2 >> /seance/web01/marker' || t_diag "writing on alpha failed"

t_rc 0 "a second tick runs straight through the foreign snapshots" \
    -- estate_replicate

t_like "$( nz bravo list -H -o name -t snapshot -r "${WEB_ON_BRAVO}" )" \
    'zrepl_20200101_000000_000' \
    "the foreign snapshot on the replica is still there: it was never seance's to destroy"
t_like "$( nz alpha list -H -o name -t snapshot -r "${ALPHA_DS}/web01" )" \
    'backup-before-the-upgrade' \
    "and neither was the one on the source"

# A dataset in the standby tree whose only snapshots are foreign is not a
# guest, whatever it is called.
nz bravo create -o canmount=noauto -o mountpoint=none \
    "${BRAVO_DS}/standby/alpha/ghost01" || t_diag "creating ghost01 failed"
nz bravo snapshot "${BRAVO_DS}/standby/alpha/ghost01@zrepl_20200101_000000_001" ||
    t_diag "planting ghost01's foreign snapshot failed"

# ---------------------------------------------------------------------------
# 1b. A CHILD DATASET AHEAD OF ITS ROOT (decision D-85)
#
# Sends are per dataset (D-64), so a tick that died part way leaves a child at
# a later instant than its root -- observed in tests/tier6/t_interrupt.sh. The
# newest snapshot anywhere in that tree names an instant no complete copy of
# the guest exists at. The promotion point is the newest instant the WHOLE tree
# shares, and anything ahead of it is rolled back before the mount.
#
# Fabricated here on web01's replica on BRAVO, which is the node that will
# promote it.
# ---------------------------------------------------------------------------

AHEAD=$( date -u -r "$(( $( date -u +%s ) + 900 ))" +%Y%m%dT%H%M%SZ )
POINT=$( nz bravo list -H -o name -t snapshot "${WEB_ON_BRAVO}" |
    sed -n '$s/.*@seance-alpha-//p' )

t_like "${POINT}" '^[0-9]{8}T[0-9]{6}Z$' \
    "web01's replica root has a known instant to be the promotion point"

nz bravo snapshot "${WEB_ON_BRAVO}/data@seance-alpha-${AHEAD}" ||
    t_diag "fabricating the child-ahead snapshot failed"

t_like "$( nz bravo list -H -o name -t snapshot -r "${WEB_ON_BRAVO}" )" \
    "${WEB_ON_BRAVO}/data@seance-alpha-${AHEAD}" \
    "the fixture is real: the child now carries an instant the root does not"

# ---------------------------------------------------------------------------
# 1c. A hand-mounted replica
#
# Somebody set a mountpoint on a standby dataset and mounted it. seance may
# REPAIR that or REFUSE it, and what is asserted is that it did exactly one of
# the two and said which -- what it may not do is proceed as though the tree
# were clean (DESIGN §6 invariant 4a names the same either/or).
#
# It runs HERE, before alpha dies, and deliberately: once alpha's estate has
# been promoted, every guest of alpha's is held on alpha (a peer claims it) and
# `repl` skips a held guest by design. The tick would then refuse for a reason
# that has nothing to do with the hand-mount, and this assertion would be
# measuring the wrong refusal. (Found by this stage's first real run, where it
# did exactly that.)
# ---------------------------------------------------------------------------

WEB_ON_CHARLIE=$( estate_replica_root charlie alpha web01 )

t_is "$( nz charlie get -H -o value mountpoint "${WEB_ON_CHARLIE}" )" "none" \
    "web01's replica on charlie is hidden, as the law requires"

node_sh charlie "mkdir -p /tmp/handmount && zfs set mountpoint=/tmp/handmount ${WEB_ON_CHARLIE} && zfs mount ${WEB_ON_CHARLIE}" ||
    t_diag "hand-mounting the replica failed"

t_isnt "$( nz charlie get -H -o value mountpoint "${WEB_ON_CHARLIE}" )" "none" \
    "the fixture is real: the replica now carries a mountpoint of its own"

HAND=$( t_tmpdir )/hand.out
node_seance alpha repl --guest web01 --peer charlie --now > "${HAND}" 2>&1
HAND_RC=$?

REPAIRED=no
REFUSED=no

if grep -q 'repaired mountpoint' "${HAND}"; then
    REPAIRED=yes
fi
if [ "${HAND_RC}" -ne 0 ]; then
    REFUSED=yes
fi

t_diag "the tick exited ${HAND_RC}; repaired=${REPAIRED} refused=${REFUSED}"

if [ "${REPAIRED}" = "yes" ]; then
    t_ok "seance REPAIRED the hand-mounted replica, and said so in its log"
    t_is "$( nz charlie get -H -o value mountpoint "${WEB_ON_CHARLIE}" )" "none" \
        "and the law holds again afterwards"
elif [ "${REFUSED}" = "yes" ]; then
    t_ok "seance REFUSED to tick over a hand-mounted replica"
    t_like "$( cat "${HAND}" )" '(err|FAIL|cannot)' \
        "and said why, loudly"
else
    t_not_ok "seance neither repaired nor refused a hand-mounted replica"
    t_not_ok "it proceeded as though the tree were clean, which is the one answer it may not give"
    sed -e 's/^/# tick: /' "${HAND}"
fi

# ---------------------------------------------------------------------------
# 2. A replica stamped in the future
# ---------------------------------------------------------------------------

FUTURE=$( date -u -r "$(( $( date -u +%s ) + 7200 ))" +%Y%m%dT%H%M%SZ )
nz bravo snapshot -r "${DB_ON_BRAVO}@seance-alpha-${FUTURE}" ||
    t_diag "fabricating the future-stamped replica snapshot failed"

cluster_stop alpha || t_diag "cluster_stop alpha failed"

HOSTILE=$( t_tmpdir )/promote.out
node_seance bravo promote alpha > "${HOSTILE}" 2>&1
HOSTILE_RC=$?

t_is "${HOSTILE_RC}" "1" \
    "a promotion carrying a skewed replica does not exit 0, even though another guest was fine"
t_like "$( cat "${HOSTILE}" )" '^  db01: force-only' \
    "the skewed guest is force-only: a human may accept a fiction, arithmetic may not"
t_like "$( cat "${HOSTILE}" )" 'seance promote alpha --force=lineage --guest db01' \
    "and the line says exactly what to run"
t_like "$( cat "${HOSTILE}" )" '^  web01: lineage proceed' \
    "the guest that was fine was still promoted"

t_unlike "$( cat "${HOSTILE}" )" 'ghost01' \
    "ghost01 was never in the estate: a dataset with no @seance-alpha-* snapshot is not a guest"

t_is "$( node_seance bravo placement | awk -F "${TAB}" '$1 == "placement" { print $2 }' | \
    LC_ALL=C sort | tr '\n' ' ' )" "web01 " \
    "and only the guest that proceeded was claimed"

# --- and web01 was promoted at the COMMON instant, not the child's ----------
t_like "$( cat "${HOSTILE}" )" "promotion point ${POINT}" \
    "web01 was promoted at the instant its whole tree shared, not at the child's"
t_like "$( cat "${HOSTILE}" )" "destroying ${WEB_ON_BRAVO}/data@seance-alpha-${AHEAD}" \
    "and the snapshot that ran ahead was named before it was destroyed"

t_rc 1 "the child's extra snapshot is gone: zfs rollback -r took it" \
    -- nz bravo list -H -o name -t snapshot "${WEB_ON_BRAVO}/data@seance-alpha-${AHEAD}"

t_is "$( nz bravo list -H -o name -t snapshot -r "${WEB_ON_BRAVO}" |
    sed 's/.*@//' | grep '^seance-alpha-' | LC_ALL=C sort -u | tail -1 )" \
    "seance-alpha-${POINT}" \
    "every dataset of the promoted guest now sits at the same instant"

FORCED=$( t_tmpdir )/forced.out
node_seance bravo promote alpha --guest db01 --force=lineage > "${FORCED}" 2>&1
FORCED_RC=$?

t_is "${FORCED_RC}" "0" "--force=lineage promotes the skewed guest"
t_like "$( cat "${FORCED}" )" '^  db01: lineage proceed-forced' \
    "and says it was forced"
t_like "$( cluster_exec bravo cat /var/db/seance/succession.log < /dev/null )" \
    "^db01${TAB}alpha${TAB}bravo${TAB}[0-9]{8}T[0-9]{6}Z${TAB}force:" \
    "the record carries the operator, not the fence, as its evidence"


t_done
