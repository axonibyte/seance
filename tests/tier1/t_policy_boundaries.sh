#!/bin/sh
# Tier 1 -- the wire protocol at its edges.
#
# t_policy_time.sh walks the calendar and t_policy_snap.sh walks the grammar.
# This file stands at the ends of both and pushes: the first second the format
# can express and the last, the 2038 second that ends a signed 32-bit epoch and
# the one after it, a node field of one character and one of sixty-three, and
# the node a fleet gets when somebody names a machine after the tool.
#
# The node named 'seance' is not a joke case. The name is
# 'seance-<node>-<ts>', the prefix is stripped once from the LEFT and the
# timestamp is taken from the RIGHT, so 'seance-seance-<ts>' is only
# unambiguous because those two rules never meet in the middle. An
# implementation that stripped 'seance-' greedily, or searched for the first
# dash rather than the last, would read that name as a different node or as no
# node at all -- and would do it silently, on the one node whose replicas
# nobody would think to check.
#
# The asymmetry between the two functions is asserted here as a pair, because
# it is a decision (D-36) and not an accident: pol_snap_format writes only the
# [a-z0-9]+ config keys, and pol_snap_parse accepts every character ZFS
# permits in a snapshot name. Strict in what we send, liberal in what we
# accept -- and a test that only ever exercised names seance wrote would never
# notice the second half going away.
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

TAB=$( printf '\t.' )
TAB=${TAB%.}

# A node key of exactly sixty-three characters, and one of exactly one. Both
# are [a-z0-9]+, so both are keys seance would itself write.
K63=$( awk 'BEGIN { while (i++ < 63) printf "n" }' )
K1=a

# newest <node> <line...>  -- pol_newest_for_node over the given listing lines.
#
# shellcheck disable=SC2329
#   Invoked indirectly by t_stdout_is/t_rc, which run the command after '--'.
newest()
{
    local _node

    _node=$1
    shift

    printf '%s\n' "$@" | pol_newest_for_node "${_node}"
}

# keep <now> <recent> <hourly> <ts...>
#
# shellcheck disable=SC2329
#   Invoked indirectly by t_stdout_is, as above.
keep()
{
    local _now _recent _hourly

    _now=$1
    _recent=$2
    _hourly=$3
    shift 3

    printf '%s\n' "$@" | pol_retention_keep "${_now}" "${_recent}" "${_hourly}"
}

t_plan 34

# --- the fixture is the size it claims to be -------------------------------

t_is "$( printf '%s' "${K63}" | wc -c | tr -d ' ' )" "63" \
    "the long node key really is sixty-three characters"

# --- format: strict in what we send ----------------------------------------

t_stdout_is "seance-${K1}-19700101T000000Z" \
    "a one-character node at the first second the format can express" -- \
    pol_snap_format "${K1}" 19700101T000000Z

t_stdout_is "seance-${K63}-99991231T235959Z" \
    "a sixty-three-character node at the last second it can express" -- \
    pol_snap_format "${K63}" 99991231T235959Z

t_stdout_is "seance-seance-20260816T101500Z" \
    "a node named after the tool is a node like any other" -- \
    pol_snap_format seance 20260816T101500Z

t_stdout_is "seance-alpha-20380119T031408Z" \
    "the second after the signed 32-bit epoch ends is nothing special here" -- \
    pol_snap_format alpha 20380119T031408Z

t_rc 2 "format refuses a node key with a dash: we write only config keys" -- \
    pol_snap_format node-with-dashes 20260816T101500Z
t_rc 2 "format refuses a node key with a capital in it" -- \
    pol_snap_format Alpha 20260816T101500Z
t_rc 2 "format refuses a node key with a dot in it" -- \
    pol_snap_format host.example.net 20260816T101500Z
t_rc 2 "format refuses the leap second the calendar does not have" -- \
    pol_snap_format alpha 20260816T235960Z
t_rc 2 "format refuses a timestamp one second past the last expressible one" -- \
    pol_snap_format alpha 100000101T000000Z

# --- parse: liberal in what we accept --------------------------------------

t_stdout_is "seance${TAB}20260816T101500Z" \
    "parse reads a node named 'seance' -- prefix from the left, stamp from the right" -- \
    pol_snap_parse seance-seance-20260816T101500Z

t_stdout_is "seance-alpha${TAB}20260816T101500Z" \
    "and a node whose name begins with the tool's own name" -- \
    pol_snap_parse seance-seance-alpha-20260816T101500Z

t_stdout_is "${K63}${TAB}00010101T000000Z" \
    "a sixty-three-character node at the first second of year one" -- \
    pol_snap_parse "seance-${K63}-00010101T000000Z"

t_rc 1 "'seance-seance' alone is foreign: there is no timestamp in it" -- \
    pol_snap_parse seance-seance

t_rc 1 "a node named 'seance' does not rescue a leap-second stamp" -- \
    pol_snap_parse seance-seance-20260816T235960Z

t_rc 1 "nor does a sixty-three-character one rescue a day February does not have" -- \
    pol_snap_parse "seance-${K63}-20260229T101500Z"

# --- pol_ts_hour: the bucket the retention ladder counts in ----------------

t_stdout_is "19700101T00" "the hour bucket of the epoch itself" -- \
    pol_ts_hour 19700101T000000Z
t_stdout_is "99991231T23" "the hour bucket of the last expressible second" -- \
    pol_ts_hour 99991231T235959Z
t_stdout_is "20380119T03" "the hour bucket of the 2038 rollover" -- \
    pol_ts_hour 20380119T031407Z
t_is "$( pol_ts_hour 20260816T000000Z )/$( pol_ts_hour 20260816T005959Z )" \
    "20260816T00/20260816T00" \
    "midnight and the last second before one o'clock share a bucket"
t_isnt "$( pol_ts_hour 20260816T005959Z )" "$( pol_ts_hour 20260816T010000Z )" \
    "and one o'clock starts a new one"
t_rc 2 "ts_hour refuses a stamp it could not parse rather than truncating it" -- \
    pol_ts_hour 20260816T235960Z

# --- age and staleness across the 2038 boundary ----------------------------
#
# Epoch arithmetic in FreeBSD sh is 64-bit, so 2038 is not a cliff -- but it is
# where a 32-bit assumption anywhere in the chain would show, and it costs one
# assertion to know.

t_stdout_is "1" "an age measured across the 2038 second is one second" -- \
    pol_age 20380119T031407Z 2147483648 0
t_stdout_is "0" "a stamp exactly at now is age zero" -- \
    pol_age 20380119T031407Z 2147483647 0
t_rc 1 "a stamp one second past now, beyond tolerance, is a skew violation" -- \
    pol_age 20380119T031408Z 2147483647 0
t_rc 0 "the same stamp inside the tolerance is age zero and no complaint" -- \
    pol_age 20380119T031408Z 2147483647 1

t_rc 1 "an age of a whole century is stale against any real threshold" -- \
    pol_is_stale 3155760000 604800
t_rc 0 "and an age of zero is fresh against the smallest one" -- \
    pol_is_stale 0 60

# --- pol_newest_for_node at the edges --------------------------------------

t_stdout_is "20270816T101500Z" \
    "the newest for a node named 'seance', among its own and others'" -- \
    newest seance \
        "tank/g@seance-seance-20260816T101500Z" \
        "tank/g@seance-seance-20270816T101500Z" \
        "tank/g@seance-alpha-20280816T101500Z" \
        "tank/g@zrepl-seance-20290816T101500Z"

t_stdout_is "20260816T101500Z" \
    "a one-character node is not answered by a two-character one" -- \
    newest "${K1}" \
        "tank/g@seance-${K1}-20260816T101500Z" \
        "tank/g@seance-${K1}b-20270816T101500Z"

t_rc 1 "and the two-character node's own lineage is not found under the one" -- \
    newest "${K1}c" "tank/g@seance-${K1}-20260816T101500Z"

t_stdout_is "99991231T235959Z" \
    "the newest is chosen by the protocol's ordering across the whole range" -- \
    newest "${K63}" \
        "tank/g@seance-${K63}-99991231T235959Z" \
        "tank/g@seance-${K63}-00010101T000000Z" \
        "tank/g@seance-${K63}-20260816T101500Z"

# --- retention at the ends of the range ------------------------------------

t_stdout_is "99991231T235959Z" \
    "a snapshot at the end of time is kept, not aged out by arithmetic" -- \
    keep 253402300799 60 120 99991231T235959Z 99991231T235959Z

t_stdout_is "00010101T000000Z" \
    "and one from year one is still the newest of its own hour" -- \
    keep -62135596800 60 120 00010101T000000Z

t_done
