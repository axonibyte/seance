#!/bin/sh
# Tier 1 -- timestamp validation and the epoch/civil arithmetic.
#
# seance's time arithmetic is pure integer arithmetic, not date(1): the
# timestamp in a snapshot name is UTC always, and an implementation that
# reached for the C library would inherit TZ and LC_TIME and would then be
# wrong on precisely the node whose clock nobody checked. This file tests the
# arithmetic against hand-checked civil dates; tier 2 tests it against epochs
# that date(1) computed independently, under a non-UTC TZ.
#
# The leap-year cases are here because they are the ones a hand-rolled
# calendar gets wrong: 2000 is a leap year (divisible by 400), 1900 and 2100
# are not (divisible by 100 but not 400), and both mistakes shift every
# subsequent date by a day.
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

t_plan 159

# --- pol_ts_valid: the shape ----------------------------------------------

while IFS='|' read -r ts want; do
    case "${ts}" in
        ''|'#'*) continue ;;
    esac
    t_rc "${want}" "ts_valid rc ${want}: ${ts}" -- pol_ts_valid "${ts}"
done <<'TABLE'
20260816T101500Z|0
19700101T000000Z|0
20991231T235959Z|0
00010101T000000Z|0
00000101T000000Z|0
99991231T235959Z|0
20000229T120000Z|0
20240229T120000Z|0
19000228T120000Z|0
21000228T120000Z|0
20260816T101500|1
20260816T101500z|1
20260816t101500Z|1
2026081T101500Z|1
202608166T101500Z|1
20260816 101500Z|1
20261316T101500Z|1
20260016T101500Z|1
20260832T101500Z|1
20260800T101500Z|1
20260229T101500Z|1
19000229T101500Z|1
21000229T101500Z|1
20260816T241500Z|1
20260816T106000Z|1
20260816T101560Z|1
20260816T235959Z|0
20260816T-01500Z|1
2026-816T101500Z|1
||1
TABLE

# The empty argument, which the table cannot express as a first field.
t_rc 1 "ts_valid rc 1: no argument at all" -- pol_ts_valid

# --- pol_ts_to_epoch: hand-checked civil dates ----------------------------
#
# Each of these is a date whose epoch second is independently known: the epoch
# itself, the leap-second-free day boundaries around it, the 2000 leap day,
# and the century boundaries the leap rule turns on.

while IFS='|' read -r ts epoch; do
    case "${ts}" in
        ''|'#'*) continue ;;
    esac
    t_stdout_is "${epoch}" "ts_to_epoch ${ts}" -- pol_ts_to_epoch "${ts}"
    t_stdout_is "${ts}" "epoch_to_ts ${epoch}" -- pol_epoch_to_ts "${epoch}"
done <<'TABLE'
19700101T000000Z|0
19700101T000001Z|1
19700101T235959Z|86399
19700102T000000Z|86400
19691231T235959Z|-1
19691231T000000Z|-86400
19000101T000000Z|-2208988800
19000301T000000Z|-2203891200
20000229T000000Z|951782400
20000301T000000Z|951868800
21000228T000000Z|4107456000
21000301T000000Z|4107542400
19991231T235959Z|946684799
20000101T000000Z|946684800
20240229T120000Z|1709208000
20260816T101500Z|1786875300
20261231T235959Z|1798761599
20270101T000000Z|1798761600
00010101T000000Z|-62135596800
99991231T235959Z|253402300799
20200229T000000Z|1582934400
20200301T000000Z|1583020800
20380119T031407Z|2147483647
20380119T031408Z|2147483648
TABLE

# --- boundary behaviour of the converters ---------------------------------

t_rc 2 "ts_to_epoch refuses a non-timestamp" -- pol_ts_to_epoch notatime
t_rc 2 "ts_to_epoch refuses an impossible date" -- \
    pol_ts_to_epoch 20260229T000000Z
t_rc 2 "epoch_to_ts refuses a non-integer" -- pol_epoch_to_ts twelve
t_rc 2 "epoch_to_ts refuses an empty argument" -- pol_epoch_to_ts ''
t_rc 0 "epoch_to_ts accepts a negative integer" -- pol_epoch_to_ts -1
t_rc 2 "epoch_to_ts refuses a year past 9999" -- pol_epoch_to_ts 253402300800
t_rc 2 "epoch_to_ts refuses a year before 0000" -- \
    pol_epoch_to_ts -62167219201

# --- pol_ts_cmp ------------------------------------------------------------

while IFS='|' read -r a b want; do
    case "${a}" in
        ''|'#'*) continue ;;
    esac
    t_stdout_is "${want}" "ts_cmp ${a} ${b}" -- pol_ts_cmp "${a}" "${b}"
done <<'TABLE'
20260816T101500Z|20260816T101500Z|0
20260816T101500Z|20260816T101501Z|-1
20260816T101501Z|20260816T101500Z|1
20260816T101500Z|20260816T102500Z|-1
20260816T101500Z|20260816T111500Z|-1
20260816T101500Z|20260817T101500Z|-1
20260816T101500Z|20260916T101500Z|-1
20260816T101500Z|20270816T101500Z|-1
20270816T101500Z|20260816T101500Z|1
19700101T000000Z|99991231T235959Z|-1
00010101T000000Z|00010101T000001Z|-1
TABLE

t_rc 2 "ts_cmp refuses a non-timestamp on the left" -- \
    pol_ts_cmp junk 20260816T101500Z
t_rc 2 "ts_cmp refuses a non-timestamp on the right" -- \
    pol_ts_cmp 20260816T101500Z junk

# --- the whole year, every month length -----------------------------------
#
# A month-length table is exactly the kind of thing that is right for eleven
# months. The last day of every month of a leap year and of a common year must
# be valid, and the day after it must not be.

for y in 2024 2026; do
    if [ "${y}" = 2024 ]; then feb=29; else feb=28; fi
    n=0
    for len in 31 ${feb} 31 30 31 30 31 31 30 31 30 31; do
        n=$(( n + 1 ))
        mm=$( printf '%02d' "${n}" )
        t_rc 0 "${y}-${mm}-${len} is a real day" -- \
            pol_ts_valid "${y}${mm}$( printf '%02d' "${len}" )T000000Z"
        t_rc 1 "${y}-${mm}-$(( len + 1 )) is not" -- \
            pol_ts_valid "${y}${mm}$( printf '%02d' $(( len + 1 )) )T000000Z"
    done
done

# --- round trip over a spread of instants ---------------------------------

for e in 0 1 59 60 3599 3600 86399 86400 946684800 1786875300 \
         -1 -86400 -2208988800; do
    t_is "$( pol_ts_to_epoch "$( pol_epoch_to_ts "${e}" )" )" "${e}" \
        "epoch round trip ${e}"
done

t_done
