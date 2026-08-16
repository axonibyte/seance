#!/bin/sh
# Tier 1 -- the snapshot-name grammar (handoff §2.1, TESTING.md §2).
#
# The snapshot name is the wire protocol: a survivor works out lineage and
# staleness from names alone, so a parser that is wrong here is a promotion
# that reads the wrong replica. The pathological cases are the point -- node
# names contain dashes, and one of them may itself end in something that looks
# like a timestamp, which is why the grammar is parsed from the right.
#
# The committed vector file (tier 2) is the oracle for the parse; this file
# tests the surrounding contract: what formats, what splits, what is rejected
# and with which exit status.
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

t_plan 60

# --- pol_snap_format -------------------------------------------------------

t_stdout_is "seance-alpha-20260816T101500Z" "format: a plain node key" -- \
    pol_snap_format alpha 20260816T101500Z
t_stdout_is "seance-n1-19700101T000000Z" "format: digits in the key" -- \
    pol_snap_format n1 19700101T000000Z

# Format is strict where parse is liberal: seance writes only the config node
# key, which is [a-z0-9]+ by D-4, so anything else is a caller bug (rc 2).
t_rc 2 "format: rejects a dashed node key" -- \
    pol_snap_format node-with-dash 20260816T101500Z
t_rc 2 "format: rejects an uppercase node key" -- \
    pol_snap_format Alpha 20260816T101500Z
t_rc 2 "format: rejects an empty node key" -- \
    pol_snap_format "" 20260816T101500Z
t_rc 2 "format: rejects an underscore in the node key" -- \
    pol_snap_format node_a 20260816T101500Z
t_rc 2 "format: rejects an invalid timestamp" -- \
    pol_snap_format alpha 20261316T101500Z
t_rc 2 "format: rejects a timestamp without its Z" -- \
    pol_snap_format alpha 20260816T101500
t_stdout_is "" "format: prints nothing when it refuses" -- \
    pol_snap_format alpha nonsense

# --- pol_snap_parse --------------------------------------------------------

# input | expected node | expected timestamp   ('-' in both means foreign)
while IFS='|' read -r in node ts; do
    case "${in}" in
        ''|'#'*) continue ;;
    esac

    if [ "${node}" = "-" ] && [ "${ts}" = "-" ]; then
        t_rc 1 "parse: foreign, ignored not fatal: ${in}" -- \
            pol_snap_parse "${in}"
        t_stdout_is "" "parse: prints nothing for foreign: ${in}" -- \
            pol_snap_parse "${in}"
    else
        t_stdout_is "${node}${TAB}${ts}" "parse: ${in}" -- \
            pol_snap_parse "${in}"
    fi
done <<'TABLE'
seance-alpha-20260816T101500Z|alpha|20260816T101500Z
seance-node-with-dashes-20260816T101500Z|node-with-dashes|20260816T101500Z
seance-node-20260816T101500Z-20260816T101500Z|node-20260816T101500Z|20260816T101500Z
seance-1234567890123456-20260816T101500Z|1234567890123456|20260816T101500Z
seance-a.b:c_d-20260816T101500Z|a.b:c_d|20260816T101500Z
seance-Alpha-20260816T101500Z|Alpha|20260816T101500Z
zrepl-alpha-20260816T101500Z|-|-
seance-alpha-20260816T101500|-|-
seance-alpha-20260816101500Z|-|-
seance-alpha-20261316T101500Z|-|-
seance--20260816T101500Z|-|-
seance-20260816T101500Z|-|-
seance-alpha-|-|-
seance-|-|-
seance|-|-
|-|-
SEANCE-alpha-20260816T101500Z|-|-
seance-node with space-20260816T101500Z|-|-
TABLE

# --- pol_snap_split --------------------------------------------------------

t_stdout_is "pool/guests/db${TAB}seance-alpha-20260816T101500Z" \
    "split: dataset and short name" -- \
    pol_snap_split "pool/guests/db@seance-alpha-20260816T101500Z"
t_stdout_is "pool${TAB}seance-alpha-20260816T101500Z" \
    "split: a dataset at the pool root" -- \
    pol_snap_split "pool@seance-alpha-20260816T101500Z"

t_rc 1 "split: refuses a name with no @" -- \
    pol_snap_split pool/guests/db
t_rc 1 "split: refuses a name with two @" -- \
    pol_snap_split 'pool/db@a@b'
t_rc 1 "split: refuses an empty dataset half" -- \
    pol_snap_split '@seance-alpha-20260816T101500Z'
t_rc 1 "split: refuses an empty snapshot half" -- \
    pol_snap_split 'pool/db@'
t_rc 1 "split: refuses an empty argument" -- \
    pol_snap_split ''

# --- pol_ts_hour -----------------------------------------------------------

t_stdout_is "20260816T10" "hour bucket: truncates to the UTC hour" -- \
    pol_ts_hour 20260816T101500Z
t_stdout_is "20260816T00" "hour bucket: midnight" -- \
    pol_ts_hour 20260816T000000Z
t_stdout_is "20260816T23" "hour bucket: the last hour of a day" -- \
    pol_ts_hour 20260816T235959Z
t_rc 2 "hour bucket: refuses a non-timestamp" -- pol_ts_hour notatime

# --- round trip ------------------------------------------------------------
#
# The two implementations that meet on the wire are the writer and the reader,
# so the property that actually matters is that one undoes the other.

for n in alpha bravo1 x; do
    for stamp in 19700101T000000Z 20000229T235959Z 20260816T101500Z \
                 20991231T235959Z; do
        t_is "$( pol_snap_parse "$( pol_snap_format "${n}" "${stamp}" )" )" \
            "${n}${TAB}${stamp}" \
            "round trip: format then parse ${n} ${stamp}"
    done
done

t_done
