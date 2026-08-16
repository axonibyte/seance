#!/bin/sh
# Tier 1 -- the promotion point: the newest instant the WHOLE guest exists at.
#
# Replication sends one dataset at a time (D-64), so a tick that died part way
# leaves a guest's datasets at different snapshots -- observed in
# tests/tier6/t_interrupt.sh, where a killed root send left the small `sys`
# child a snapshot ahead. The newest timestamp anywhere in such a tree names an
# instant that no complete copy of the guest exists at, and a guest promoted
# there is not "minutes stale" but incoherent, with nothing downstream able to
# tell (decision D-85).
#
# pol_common_newest_for_node is the whole of that rule, and it is a pure
# function of a snapshot listing, so it is tested here with no disk at all.
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

T1=20260101T000000Z
T2=20260101T001500Z
T3=20260101T003000Z

# common <nodekey> <listing>  -- the answer, or the empty string.
COMMON=""
CRC=0
common()
{
    COMMON=$( printf '%s\n' "$2" | pol_common_newest_for_node "$1" )
    CRC=$?
}

t_plan 19

# --- a healthy replica: every dataset at the same instant --------------------
common alpha "p/web01@seance-alpha-${T1}
p/web01/data@seance-alpha-${T1}
p/web01/sys@seance-alpha-${T1}"
t_is "${COMMON}" "${T1}" "a tree whose datasets are all at one instant answers with it"
t_is "${CRC}" "0" "and exits 0"

# --- several instants, all shared: the newest wins --------------------------
common alpha "p/web01@seance-alpha-${T1}
p/web01@seance-alpha-${T2}
p/web01/data@seance-alpha-${T1}
p/web01/data@seance-alpha-${T2}"
t_is "${COMMON}" "${T2}" "with several shared instants, the newest is the promotion point"

# --- THE CASE THIS EXISTS FOR: a child ahead of the root --------------------
common alpha "p/web01@seance-alpha-${T1}
p/web01/data@seance-alpha-${T1}
p/web01/data@seance-alpha-${T2}"
t_is "${COMMON}" "${T1}" \
    "a child ahead of its root does not move the point: the tree is only complete at the older instant"
t_is "${CRC}" "0" "and that is a promotable answer, not a refusal"

# The other way round, which is what an interrupted ROOT send leaves.
common alpha "p/web01@seance-alpha-${T1}
p/web01@seance-alpha-${T2}
p/web01/data@seance-alpha-${T1}"
t_is "${COMMON}" "${T1}" "a root ahead of its child is the same finding, from the other side"

# Three datasets, and the laggard decides.
common alpha "p/web01@seance-alpha-${T1}
p/web01@seance-alpha-${T2}
p/web01@seance-alpha-${T3}
p/web01/data@seance-alpha-${T1}
p/web01/data@seance-alpha-${T2}
p/web01/sys@seance-alpha-${T1}"
t_is "${COMMON}" "${T1}" "the slowest dataset in the tree sets the point, not the fastest"

# --- a dataset with nothing of ours: no coherent instant --------------------
common alpha "p/web01@seance-alpha-${T1}
p/web01/data@zrepl_20200101_000000_000"
t_is "${COMMON}" "" "a dataset carrying only another tool's snapshots shares nothing"
t_is "${CRC}" "1" "so there is no promotion point, and the caller must abort"

common alpha "p/web01@seance-alpha-${T1}
p/web01/data@seance-bravo-${T1}"
t_is "${COMMON}" "" "and neither does one carrying only another NODE's lineage"

# --- nothing at all ----------------------------------------------------------
common alpha ""
t_is "${CRC}" "1" "an empty listing has no point"
t_is "${COMMON}" "" "and prints nothing: empty is never freshness"

common alpha "p/web01@seance-bravo-${T1}
p/web01/data@seance-bravo-${T1}"
t_is "${CRC}" "1" "a tree that is coherent in ANOTHER node's lineage is not ours to promote"

# --- lines that are not snapshot references ---------------------------------
common alpha "p/web01@seance-alpha-${T1}
p/web01/data@seance-alpha-${T1}
NAME
<html>500"
t_is "${COMMON}" "${T1}" \
    "a line that is not a dataset@snapshot is not a dataset, and does not veto the point"

# A foreign snapshot BESIDE ours on the same dataset is ignored, not counted.
common alpha "p/web01@seance-alpha-${T1}
p/web01@zrepl_20200101_000000_000
p/web01/data@seance-alpha-${T1}"
t_is "${COMMON}" "${T1}" "a foreign snapshot alongside ours changes nothing"

# --- one dataset, which is the degenerate tree ------------------------------
common alpha "p/web01@seance-alpha-${T1}
p/web01@seance-alpha-${T2}"
t_is "${COMMON}" "${T2}" "a guest of one dataset is common with itself at its newest"

# --- the contract -----------------------------------------------------------
t_rc 2 "a call with no node key is a contract error" \
    -- pol_common_newest_for_node

# --- and the difference from pol_newest_for_node, stated as an assertion ----
#
# The two answer different questions and the whole decision rests on that:
# `status` wants the freshest thing here, a promotion wants the newest complete
# copy. On a broken tree they differ, and if they ever stop differing this
# assertion says so.
LISTING="p/web01@seance-alpha-${T1}
p/web01/data@seance-alpha-${T1}
p/web01/data@seance-alpha-${T2}"

t_is "$( printf '%s\n' "${LISTING}" | pol_newest_for_node alpha )" "${T2}" \
    "pol_newest_for_node still answers with the newest ANYWHERE, for status"
t_isnt "$( printf '%s\n' "${LISTING}" | pol_newest_for_node alpha )" \
    "$( printf '%s\n' "${LISTING}" | pol_common_newest_for_node alpha )" \
    "and on an interrupted tree that is NOT the promotion point"

t_done
