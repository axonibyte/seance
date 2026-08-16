#!/bin/sh
# Tier 1 -- the tier-7 seeded generator (tests/cluster/sim/gen.subr).
#
# Everything tier 7 claims about reproducibility rests on this file: a seed
# printed at the top of a run is only worth printing if replaying it deals the
# same events. So the properties asserted here are the three the claim needs
# -- the same seed gives the same sequence, different seeds give different
# ones, and the weights are the weights -- plus the two contract behaviours a
# generator can quietly get wrong and still look random: drawing a kind that
# was not offered, and answering at all before it has been seeded.
#
# The weight assertion is statistical and says so: ten thousand draws from a
# 40/60 split, asserted at 40% +/- 3 points. The tolerance is wide enough that
# no correct implementation fails it and narrow enough that an implementation
# ignoring the weights (50/50, or always the first kind) cannot pass -- which
# is the only thing a tolerance is for.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/sim/gen.subr
. "${T_ROOT}/tests/cluster/sim/gen.subr"

t_plan 18

# seq_n <seed> <count> -- the first <count> values of a seeded stream.
seq_n()
{
    local _i

    gen_seed "$1" || return 2

    _i=0
    while [ "${_i}" -lt "$2" ]; do
        gen_next || return 2
        _i=$(( _i + 1 ))
    done
}

# --- determinism ------------------------------------------------------------

A=$( seq_n 20260816 100 )
B=$( seq_n 20260816 100 )
t_is "${A}" "${B}" "the same seed deals the same 100 values"
t_is "$( printf '%s\n' "${A}" | wc -l | tr -d ' ' )" 100 \
    "a 100-value request yields 100 values"

C=$( seq_n 20260817 100 )
t_isnt "${A}" "${C}" "a different seed deals a different sequence"

# Every value is inside the 32-bit range, and none is zero -- a zero would be
# the xorshift's fixed point, from which every later value is zero too.
BAD=$( printf '%s\n' "${A}" |
    awk '$1 < 1 || $1 > 4294967295 { print }' )
t_is "${BAD}" "" "every value is in [1, 2^32-1]"

# A seed of zero must not become a stream of zeroes.
Z=$( seq_n 0 20 )
t_is "$( printf '%s\n' "${Z}" | sort -u | wc -l | tr -d ' ' )" 20 \
    "a zero seed still deals twenty distinct values"

# --- the announcement -------------------------------------------------------

gen_seed 424242
t_stdout_is '# seed 424242' "gen_announce prints '# seed <n>'" -- gen_announce

GEN_SEED=""
t_rc 2 "gen_announce refuses before gen_seed rather than inventing a seed" \
    -- gen_announce

t_rc 2 "gen_seed refuses a seed that is not a whole number" -- gen_seed 12a

t_rc 2 "gen_below refuses a bound of zero" -- gen_below 0

# --- gen_below --------------------------------------------------------------

gen_seed 99
OUT=0
i=0
while [ "${i}" -lt 500 ]; do
    gen_below 7 > /dev/null || OUT=2
    if [ "${GEN_VALUE}" -lt 0 ] || [ "${GEN_VALUE}" -gt 6 ]; then
        OUT=1
    fi
    i=$(( i + 1 ))
done
t_is "${OUT}" 0 "500 draws of gen_below 7 all land in [0, 6]"

# --- gen_choose -------------------------------------------------------------

gen_seed 7777
OUT=""
i=0
while [ "${i}" -lt 200 ]; do
    gen_choose alpha bravo charlie > /dev/null
    case "${GEN_CHOICE}" in
        alpha|bravo|charlie) ;;
        *) OUT="${OUT} ${GEN_CHOICE}" ;;
    esac
    i=$(( i + 1 ))
done
t_is "${OUT}" "" "gen_choose only ever returns a word it was given"

gen_seed 7777
D=$( gen_choose alpha bravo charlie )
gen_seed 7777
E=$( gen_choose alpha bravo charlie )
t_is "${D}" "${E}" "gen_choose is a function of the seed"

# --- gen_pick_weighted ------------------------------------------------------

# The statistical row. tick:40 kill:60 over 10000 draws; tick must land within
# three percentage points of 40%, i.e. in [3700, 4300].
gen_seed 12345
TICK=0
i=0
while [ "${i}" -lt 10000 ]; do
    gen_pick_weighted "tick:40 kill:60" > /dev/null
    [ "${GEN_PICK}" = tick ] && TICK=$(( TICK + 1 ))
    i=$(( i + 1 ))
done
if [ "${TICK}" -ge 3700 ] && [ "${TICK}" -le 4300 ]; then
    t_ok "a 40/60 split draws tick 40% of 10000 times, within 3 points"
else
    t_not_ok "a 40/60 split draws tick 40% of 10000 times, within 3 points"
    t_diag "got ${TICK} of 10000, want 3700..4300"
fi

# The applicable-subset rule (DESIGN §4): the generator draws only from the
# kinds it was offered. Offering the two that make sense right now must never
# produce a third.
gen_seed 31337
OUT=""
i=0
while [ "${i}" -lt 500 ]; do
    gen_pick_weighted "heal:6 flap:4" > /dev/null
    case "${GEN_PICK}" in
        heal|flap) ;;
        *) OUT="${OUT} ${GEN_PICK}" ;;
    esac
    i=$(( i + 1 ))
done
t_is "${OUT}" "" "a picker offered two kinds never returns a third"

# A weight of zero means never.
gen_seed 555
ZEROED=0
i=0
while [ "${i}" -lt 500 ]; do
    gen_pick_weighted "tick:10 heal:0" > /dev/null
    [ "${GEN_PICK}" = heal ] && ZEROED=$(( ZEROED + 1 ))
    i=$(( i + 1 ))
done
t_is "${ZEROED}" 0 "a kind weighted zero is never drawn"

t_rc 2 "gen_pick_weighted refuses a spec entry that is not kind:weight" \
    -- gen_pick_weighted "tick kill:6"

t_rc 2 "gen_pick_weighted refuses a spec with no weight at all" \
    -- gen_pick_weighted "tick:0 kill:0"

# And it must refuse in its own words. gen_below would refuse a bound of zero
# anyway, so without this row the empty-spec guard could be deleted and every
# assertion would still pass -- while the diagnostic an operator reads changed
# from "this spec has nothing in it" to "somebody asked for a bound of zero".
ERRF=$( t_tmpdir )/err
gen_pick_weighted "tick:0 kill:0" > /dev/null 2> "${ERRF}"
t_like "$( cat "${ERRF}" )" 'no weight to draw from' \
    "an all-zero spec is refused by the spec check, not by gen_below"

t_done
