#!/bin/sh
# Tier 1 -- quorum, succession order, and who acts (TESTING.md §2).
#
# The rule is `1 + reachable_others > N/2`, evaluated as `2*(1+r) > N` so that
# integer division can never round a half-split up into a majority. The
# boundary cases are the whole test: N=4 with two survivors must act, N=4 split
# two-and-two must freeze, N=2 must freeze the moment its peer dies (v1 has no
# witness), and a node that can reach nobody must assume it is the isolated one
# and do nothing, loudly.
#
# Freezing is not a bug being tolerated. It sacrifices availability and never
# consistency, and a test that "fixed" a freeze into an act would be reverting
# the reason seance exists.
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

t_plan 107

# --- the required table ----------------------------------------------------
#
# N | reachable others | verdict | rc

while IFS='|' read -r n r want rc; do
    case "${n}" in
        ''|'#'*) continue ;;
    esac
    t_stdout_is "${want}" "quorum N=${n} r=${r} -> ${want}" -- \
        pol_quorum "${n}" "${r}"
    t_rc "${rc}" "quorum N=${n} r=${r} -> rc ${rc}" -- pol_quorum "${n}" "${r}"
done <<'TABLE'
3|1|act|0
3|0|freeze|1
3|2|act|0
4|2|act|0
4|1|freeze|1
4|3|act|0
4|0|freeze|1
2|0|freeze|1
2|1|act|0
5|2|act|0
5|1|freeze|1
5|3|act|0
5|0|freeze|1
6|2|freeze|1
6|3|act|0
7|3|act|0
7|2|freeze|1
1|0|reject|2
0|0|reject|2
3|3|reject|2
2|2|reject|2
5|5|reject|2
TABLE

# Malformed input is rejected, not guessed at: a quorum computed from a
# miscount is worse than no answer.
t_stdout_is "reject" "quorum rejects a negative N" -- pol_quorum -1 0
t_rc 2 "quorum rejects a negative N with rc 2" -- pol_quorum -1 0
t_stdout_is "reject" "quorum rejects a negative reachable count" -- \
    pol_quorum 3 -1
t_stdout_is "reject" "quorum rejects a non-integer N" -- pol_quorum three 1
t_stdout_is "reject" "quorum rejects a non-integer reachable count" -- \
    pol_quorum 3 one
t_stdout_is "reject" "quorum rejects an empty N" -- pol_quorum '' 1
t_rc 2 "quorum rejects an empty reachable count" -- pol_quorum 3 ''

# --- pol_heirs -------------------------------------------------------------

t_stdout_is "bravo
charlie" "heirs: the node's own order" -- pol_heirs bravo charlie "" ""
t_stdout_is "bravo" "heirs: a node with one heir" -- pol_heirs bravo "" "" ""
t_rc 1 "heirs: a node with no heir is not inheritable" -- \
    pol_heirs "" "" "" ""
t_stdout_is "" "heirs: prints nothing when there is no heir" -- \
    pol_heirs "" "" "" ""

# A guest override replaces the node order entirely -- it does not extend it.
t_stdout_is "delta
echo" "heirs: a guest override wins entirely" -- \
    pol_heirs bravo charlie delta echo
t_stdout_is "delta" "heirs: a guest override with one heir is one heir" -- \
    pol_heirs bravo charlie delta ""
t_stdout_is "bravo
charlie" "heirs: a guest heir2 alone does not override" -- \
    pol_heirs bravo charlie "" delta

# De-duplication, so that a config naming the same node twice does not produce
# a succession list that tries the same node twice.
t_stdout_is "bravo" "heirs: a repeated heir appears once" -- \
    pol_heirs bravo bravo "" ""
t_stdout_is "delta" "heirs: a repeated guest heir appears once" -- \
    pol_heirs bravo charlie delta delta

# --- pol_am_i_actor --------------------------------------------------------
#
# self | heir1 | heir2 | heir1_reachable | verdict | rc

while IFS='|' read -r self h1 h2 reach want rc; do
    case "${self}" in
        ''|'#'*) continue ;;
    esac
    t_stdout_is "${want}" \
        "actor: self=${self} h1=${h1} h2=${h2} reach=${reach}" -- \
        pol_am_i_actor "${self}" "${h1}" "${h2}" "${reach}"
    t_rc "${rc}" \
        "actor rc: self=${self} h1=${h1} h2=${h2} reach=${reach}" -- \
        pol_am_i_actor "${self}" "${h1}" "${h2}" "${reach}"
done <<'TABLE'
bravo|bravo|charlie|1|act|0
bravo|bravo|charlie|0|act|0
charlie|bravo|charlie|1|stand-down|1
charlie|bravo|charlie|0|act|0
delta|bravo|charlie|0|stand-down|1
delta|bravo|charlie|1|stand-down|1
charlie||charlie|0|act|0
charlie||charlie|1|stand-down|1
bravo|bravo||1|act|0
bravo|||0|stand-down|1
TABLE

t_rc 2 "actor: refuses an empty self" -- pol_am_i_actor "" bravo charlie 1
t_rc 2 "actor: refuses a non-boolean reachability" -- \
    pol_am_i_actor bravo bravo charlie yes
t_rc 2 "actor: refuses an empty reachability" -- \
    pol_am_i_actor bravo bravo charlie ""

# Exactly one actor per failure, which is the invariant the whole thing exists
# to serve. Ask every node that is still alive, and note that a node always
# reaches itself: heir1_reachable is 1 for heir1 by construction, so the
# combination "I am heir1 and heir1 is unreachable" is not a scenario, it is a
# caller bug, and is not what this counts.
#
# Scenario A: alpha is the corpse, its heirs are bravo then charlie, and both
# survive. Scenario B: alpha is the corpse and bravo has died with it.

acted=0
for self in bravo charlie; do
    if pol_am_i_actor "${self}" bravo charlie 1 > /dev/null; then
        acted=$(( acted + 1 ))
    fi
done
t_is "${acted}" "1" "exactly one survivor acts when the first heir is alive"

acted=0
if pol_am_i_actor charlie bravo charlie 0 > /dev/null; then
    acted=$(( acted + 1 ))
fi
t_is "${acted}" "1" "exactly one survivor acts when the first heir is gone"

# --- staleness boundaries --------------------------------------------------

t_rc 0 "stale: an age below the threshold is fresh" -- pol_is_stale 2699 2700
t_rc 0 "stale: an age exactly at the threshold is fresh" -- \
    pol_is_stale 2700 2700
t_rc 1 "stale: one second past the threshold is stale" -- \
    pol_is_stale 2701 2700
t_rc 0 "stale: age zero is fresh" -- pol_is_stale 0 2700
t_rc 1 "stale: a zero threshold makes any age stale" -- pol_is_stale 1 0
t_rc 0 "stale: a zero threshold leaves age zero fresh" -- pol_is_stale 0 0
t_rc 2 "stale: refuses a non-integer age" -- pol_is_stale old 2700
t_rc 2 "stale: refuses a non-integer threshold" -- pol_is_stale 10 soon

# --- clock skew ------------------------------------------------------------

now=$( pol_ts_to_epoch 20260816T120000Z )

t_stdout_is "3600" "age: an hour old" -- \
    pol_age 20260816T110000Z "${now}" 120
t_stdout_is "0" "age: exactly now" -- pol_age 20260816T120000Z "${now}" 120
t_stdout_is "0" "age: one second into the future, inside tolerance" -- \
    pol_age 20260816T120001Z "${now}" 120
t_rc 0 "age: inside tolerance is not a violation" -- \
    pol_age 20260816T120001Z "${now}" 120
t_stdout_is "0" "age: exactly at the tolerance is still not a violation" -- \
    pol_age 20260816T120200Z "${now}" 120
t_rc 0 "age: at the tolerance, rc 0" -- \
    pol_age 20260816T120200Z "${now}" 120
t_stdout_is "-121" "age: one second past tolerance reports the delta" -- \
    pol_age 20260816T120201Z "${now}" 120
t_rc 1 "age: one second past tolerance is a violation" -- \
    pol_age 20260816T120201Z "${now}" 120
t_stdout_is "-3600" "age: an hour in the future reports the delta" -- \
    pol_age 20260816T130000Z "${now}" 120
t_rc 1 "age: a zero tolerance makes any future a violation" -- \
    pol_age 20260816T120001Z "${now}" 0
t_rc 0 "age: a zero tolerance leaves the present alone" -- \
    pol_age 20260816T120000Z "${now}" 0
t_rc 2 "age: refuses a non-timestamp" -- pol_age yesterday "${now}" 120
t_rc 2 "age: refuses a non-integer now" -- pol_age 20260816T110000Z soon 120
t_rc 2 "age: refuses a non-integer tolerance" -- \
    pol_age 20260816T110000Z "${now}" loose

t_done
