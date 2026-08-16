#!/bin/sh
# Tier 4 -- the lineage/staleness rungs of the promotion ladder, driven against
# the fault-injecting mock adapter (TESTING.md §5; M1 fence: these rungs only).
#
# A truth table. Every row is a state of the replica lineage crossed with an
# outcome the infrastructure can produce, and every row has ONE expected
# disposition:
#
#   present and fresh              -> proceed
#   present and stale              -> force-only, or proceed-forced with --force
#   present and skewed past skew   -> force-only, or proceed-forced with --force
#   absent                         -> abort, AND --force cannot reach it
#   listing returns empty with 0   -> abort  (THE CRASHED-VERIFIER ROW)
#   listing returns garbage with 0 -> abort
#   listing fails                  -> abort
#   listing is a usage error       -> abort, exit 2
#   listing never answers          -> the caller's timeout fires, and nothing
#                                     printed before it fired said proceed
#
# The last five are the point of the tier. Each of them is a way of NOT KNOWING
# what the replica is, and the one thing none of them may become is permission
# to promote: a promotion onto a lineage nobody could read is how a guest comes
# back as an empty disk. The August catalogue's crashed verifier -- a checker
# that died and whose silence read as success -- is the empty0 row, and it is
# an assertion here rather than a paragraph in a postmortem.
#
# The listing is the mock's, reached through SEANCE_ZFS_LIST_CMD, and the
# mock's own fixture names are formatted by the REAL pol_snap_format, so no
# name in this file was written by hand into a shape seance would not itself
# have produced (tests/tier3/t_mock_imports_real.sh guards that).
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/policy.subr
. "${T_ROOT}/lib/policy.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/lineage.subr
. "${T_ROOT}/lib/lineage.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../mock-adapter.subr
. "${T_ROOT}/tests/mock-adapter.subr"

# The snapshot listing is the mock's function, called by name in this shell.
SEANCE_ZFS_LIST_CMD=mock_zfs_list

# A fixed clock. Nothing here asks the real one; pol_now exists so that verbs
# ask once and thread the answer through, and a test that consulted it would
# be a test whose meaning changed at midnight.
NOW=1786000000
MAX=2700            # three cadences, the default staleness_max
SKEW=120            # the default skew_tolerance
DEAD=alpha
DS=pool0/web01

ERRF=$( t_tmpdir )/err
DISP=""
RC=0

# lineage <force>  -- run the rungs, keeping the disposition, the status and
# the diagnostics for the assertions that follow.
lineage()
{
    DISP=$( lineage_disposition "${DEAD}" "${DS}" "${NOW}" "${MAX}" "${SKEW}" \
        "$1" 2> "${ERRF}" )
    RC=$?
}

# scripted <line...>  -- point the mock at a one-line script.
scripted()
{
    printf '%s\n' "$@" > "${SCRIPT}"
    SEANCE_MOCK_SCRIPT=${SCRIPT}
}

# unscripted  -- back to the mock's fixtures.
unscripted()
{
    : > "${SCRIPT}"
    SEANCE_MOCK_SCRIPT=${SCRIPT}
}

SCRIPT=$( t_tmpdir )/script
SEANCE_MOCK_LOG=$( t_tmpdir )/log
export SEANCE_MOCK_LOG
unscripted

t_plan 26

# --- present and fresh ------------------------------------------------------
SEANCE_MOCK_LINEAGE_NODE=${DEAD}
SEANCE_MOCK_LINEAGE_NOW=$(( NOW - 60 ))
SEANCE_MOCK_LINEAGE_N=3
export SEANCE_MOCK_LINEAGE_NODE SEANCE_MOCK_LINEAGE_NOW SEANCE_MOCK_LINEAGE_N

lineage 0
t_is "${DISP}" "proceed" "fresh replica: proceed"
t_is "${RC}" "0" "fresh replica: exit 0"

# The probe found the newest of the three, not merely one of them.
t_is "$( lineage_probe "${DEAD}" "${DS}" )" \
    "$( pol_epoch_to_ts $(( NOW - 60 )) )" \
    "the probe reports the newest snapshot, not the first"

# --- present and stale ------------------------------------------------------
SEANCE_MOCK_LINEAGE_NOW=$(( NOW - MAX - 1 ))

lineage 0
t_is "${DISP}" "force-only" "stale replica without --force: force-only"
t_is "${RC}" "1" "stale replica without --force: exit 1"

lineage 1
t_is "${DISP}" "proceed-forced" "stale replica with --force: proceed-forced"
t_is "${RC}" "0" "stale replica with --force: exit 0"

# The boundary is D-28's: exactly at staleness_max is still fresh.
SEANCE_MOCK_LINEAGE_NOW=$(( NOW - MAX ))
lineage 0
t_is "${DISP}" "proceed" "a replica exactly at staleness_max is fresh"

# --- present but skewed into the future --------------------------------------
SEANCE_MOCK_LINEAGE_NOW=$(( NOW + SKEW + 1 ))

lineage 0
t_is "${DISP}" "force-only" "replica skewed past tolerance: force-only"
lineage 1
t_is "${DISP}" "proceed-forced" "replica skewed past tolerance, forced: proceed-forced"

# --- absent ------------------------------------------------------------------
# A lineage that exists, but belongs to another node: there is nothing here for
# the dead node, and no amount of force makes a snapshot exist.
SEANCE_MOCK_LINEAGE_NODE=bravo
SEANCE_MOCK_LINEAGE_NOW=${NOW}

lineage 0
t_is "${DISP}" "abort" "no lineage for the dead node: abort"
t_is "${RC}" "1" "no lineage for the dead node: exit 1"

lineage 1
t_is "${DISP}" "abort" "no lineage, with --force: still abort"
t_is "${RC}" "1" "no lineage, with --force: still exit 1"

SEANCE_MOCK_LINEAGE_NODE=${DEAD}

# --- the crashed verifier: empty stdout, exit 0 ------------------------------
scripted "mock_zfs_list	empty0"

lineage 0
t_is "${DISP}" "abort" "empty listing with exit 0: abort"
t_is "${RC}" "1" "empty listing with exit 0: exit 1"
t_like "$( cat "${ERRF}" )" 'printed nothing' \
    "empty listing with exit 0 is diagnosed, not passed over"

lineage 1
t_is "${DISP}" "abort" "empty listing with exit 0, forced: STILL abort"

# --- garbage with exit 0 -----------------------------------------------------
scripted "mock_zfs_list	garbage	pool0/web01@zrepl_20260101_000000_000\nnot a snapshot at all\n<html>"

lineage 0
t_is "${DISP}" "abort" "garbage listing: abort"
t_is "${RC}" "1" "garbage listing: exit 1"

# --- the listing fails -------------------------------------------------------
scripted "mock_zfs_list	fail	cannot open 'pool0/web01': dataset does not exist"

lineage 0
t_is "${DISP}" "abort" "failed listing: abort"

# --- the listing is a contract error ----------------------------------------
scripted "mock_zfs_list	usage	unknown option"

lineage 0
t_is "${DISP}" "abort" "listing usage error: abort"
t_is "${RC}" "2" "listing usage error: exit 2, a contract error"

# --- the listing never answers ------------------------------------------------
# The mock sleeps past SEANCE_MOCK_TIMEOUT and never returns. lineage.subr has
# no timeout of its own by design -- bounding a command is transport's job --
# so what is asserted here is the caller's wrapper: it fires, and nothing the
# call printed before it fired was a permission to proceed.
SEANCE_MOCK_TIMEOUT=1
export SEANCE_MOCK_TIMEOUT
scripted "mock_zfs_list	timeout"

out=$( t_run_timeout 1 lineage_disposition "${DEAD}" "${DS}" "${NOW}" "${MAX}" \
    "${SKEW}" 0 )
rc=$?

t_is "${rc}" "124" "a listing that never answers is stopped by the caller"
t_unlike "${out}" 'proceed' "a listing that never answers never printed proceed"

# --- the mock recorded what it was asked ------------------------------------
t_like "$( cat "${SEANCE_MOCK_LOG}" )" "^mock_zfs_list ${DS}\$" \
    "every listing call was recorded in SEANCE_MOCK_LOG"

t_done
