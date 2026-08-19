#!/bin/sh
# Tier 7's oracle, self-tested at tier-4 cost (TESTING.md §7, DESIGN.md §7).
#
# An invariant that never fires is indistinguishable from a passing suite.
# This file feeds tests/cluster/sim/invariants.subr and oracle.subr the states
# a *broken* seance would leave -- two nodes running one guest, a promotion
# with no fence record, a replica that went backwards, a dataset that is gone,
# a replica mounted over live data, a verb that hangs -- and requires each to
# complain. Then it feeds them a coherent world and requires silence.
#
# It runs in about three seconds with no cluster, no ZFS and no jails, which
# is why it lives in tier 4 and not tier 7: 'sh tools/lint.sh' runs tiers 1-4,
# so the oracle is checked on the workstation on every lint rather than once
# per reaper session (D-56). tests/tier7/t_sim.sh runs this file first and
# refuses to spend a session if it does not pass.
#
# The last assertion is the one that guards the rest: every invariant label
# must have been *seen* firing. Adding an invariant without a firing row for
# it fails this file.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/sim/oracle.subr
. "${T_ROOT}/tests/cluster/sim/oracle.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/sim/invariants.subr
. "${T_ROOT}/tests/cluster/sim/invariants.subr"

t_plan 52

TAB=$( printf '\t' )

# The fictional site (charter §6). Guests are named for what this module is
# about, so that nothing here can ever be mistaken for a tenant's inventory.
NODES="alpha bravo charlie"
GUESTS="ghost01 wraith02 spectre03"

TS_OLD="20260816T110000Z"
TS_NOW="20260816T120000Z"
TS_NEW="20260816T130000Z"

# Which invariants have been observed firing. The file, not a variable: some
# assertions run their invariant inside a command substitution.
SEEN=$( t_tmpdir )/fired-labels
: > "${SEEN}"

# Captures live under one directory so the harness removes them at exit.
ORACLE_CAPTURE_ROOT=$( t_tmpdir )/captures
export ORACLE_CAPTURE_ROOT

# A short bound for every oracle row: nothing here should take seconds, and a
# self-test that can itself hang for two minutes is not much of a self-test.
SEANCE_SIM_STEP_TIMEOUT=5

# ---------------------------------------------------------------------------
# Fixture construction
# ---------------------------------------------------------------------------

# row <file> <field...> -- append one tab-separated record.
row()
{
    local _f _s _a

    _f=$1
    shift

    _s=""
    for _a in "$@"; do
        if [ -z "${_s}" ]; then
            _s=${_a}
        else
            _s="${_s}${TAB}${_a}"
        fi
    done

    printf '%s\n' "${_s}" >> "${_f}"
}

# set_prop <obs> <node> <guest> <property> <value>
#
# Replaces rather than appends: obs_props reads the first row it finds for a
# property, so a fixture that appended a second one would be asserting about a
# value the checker never sees -- which is how a row comes to pass for the
# wrong reason.
set_prop()
{
    local _o _n _g _p

    _o=$1
    _n=$2
    _g=$3
    _p=$4

    grep -v "^${_n}${TAB}${_g}${TAB}${_p}${TAB}" "${_o}/props" \
        > "${_o}/props.new"
    mv "${_o}/props.new" "${_o}/props"
    row "${_o}/props" "${_n}" "${_g}" "${_p}" "$5"
}

# home_of <guest>
home_of()
{
    case "$1" in
        ghost01)   printf 'alpha\n' ;;
        wraith02)  printf 'bravo\n' ;;
        spectre03) printf 'charlie\n' ;;
        *)         printf '\n' ;;
    esac
}

# mk_model <dir> <ts> -- three live nodes, three guests at home, one lineage
# timestamp everywhere.
mk_model()
{
    local _m _ts _n _g

    _m=$1
    _ts=$2

    mkdir -p "${_m}"
    : > "${_m}/nodes"
    : > "${_m}/guests"
    : > "${_m}/lineage"

    for _n in ${NODES}; do
        row "${_m}/nodes" "${_n}" alive
    done
    for _g in ${GUESTS}; do
        row "${_m}/guests" "${_g}" "$( home_of "${_g}" )"
        for _n in ${NODES}; do
            row "${_m}/lineage" "${_g}" "${_n}" "${_ts}"
        done
    done
}

# mk_obs <dir> <ts> -- the coherent world: every guest running at home, every
# node holding a snapshot of it at <ts>, every replica inert.
mk_obs()
{
    local _o _ts _n _g _h _f

    _o=$1
    _ts=$2

    mkdir -p "${_o}"
    for _f in running placement snapshots records props datasets invocations; do
        : > "${_o}/${_f}"
    done

    for _g in ${GUESTS}; do
        _h=$( home_of "${_g}" )
        row "${_o}/running" "${_g}" "${_h}" 1
        for _n in ${NODES}; do
            row "${_o}/snapshots" "${_n}" "${_g}" "seance-${_h}-${_ts}"
            row "${_o}/datasets" "${_n}" "pool/seance/${_n}/${_g}"
            if [ "${_n}" = "${_h}" ]; then
                row "${_o}/props" "${_n}" "${_g}" canmount on
                row "${_o}/props" "${_n}" "${_g}" mountpoint "/estate/${_g}"
            else
                row "${_o}/props" "${_n}" "${_g}" canmount noauto
                row "${_o}/props" "${_n}" "${_g}" mountpoint none
            fi
        done
    done
}

# world <ts> -- a fresh coherent (model, obs) pair; prints "<model> <obs>".
world()
{
    local _d

    _d=$( t_tmpdir )
    mk_model "${_d}/model" "$1"
    mk_obs "${_d}/obs" "$1"
    printf '%s %s\n' "${_d}/model" "${_d}/obs"
}

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

# t_fires <invariant-label> <name> -- <command...>
#
# The command must exit non-zero and print at least one
# 'invariant <label> FIRED: ' line. Records the label as seen firing.
t_fires()
{
    local _lab _name _dir _rc

    _lab=$1
    shift
    _name=$1
    shift
    if [ "${1:-}" = "--" ]; then
        shift
    else
        t_not_ok "${_name}"
        t_diag "t_fires: missing '--' before the command"
        return 0
    fi

    _dir=$( t_tmpdir )
    "$@" > "${_dir}/out" 2> "${_dir}/err"
    _rc=$?

    if [ "${_rc}" -ne 0 ] &&
        grep -q "^invariant ${_lab} FIRED: " "${_dir}/out"; then
        printf '%s\n' "${_lab}" >> "${SEEN}"
        t_ok "${_name}"
    else
        t_not_ok "${_name}"
        t_diag "want: rc non-zero and an 'invariant ${_lab} FIRED:' line"
        t_diag "rc: ${_rc}"
        sed -e 's/^/# out: /' "${_dir}/out"
        sed -e 's/^/# err: /' "${_dir}/err"
    fi

    return 0
}

# t_quiet <invariant-label> <name> -- <command...>
#
# The command must exit 0, print 'invariant <label> ok', and print no FIRED
# line at all.
t_quiet()
{
    local _lab _name _dir _rc

    _lab=$1
    shift
    _name=$1
    shift
    if [ "${1:-}" = "--" ]; then
        shift
    else
        t_not_ok "${_name}"
        t_diag "t_quiet: missing '--' before the command"
        return 0
    fi

    _dir=$( t_tmpdir )
    "$@" > "${_dir}/out" 2> "${_dir}/err"
    _rc=$?

    if [ "${_rc}" -eq 0 ] &&
        grep -q "^invariant ${_lab} ok" "${_dir}/out" &&
        ! grep -q 'FIRED' "${_dir}/out"; then
        t_ok "${_name}"
    else
        t_not_ok "${_name}"
        t_diag "want: rc 0, an 'invariant ${_lab} ok' line, and no FIRED line"
        t_diag "rc: ${_rc}"
        sed -e 's/^/# out: /' "${_dir}/out"
        sed -e 's/^/# err: /' "${_dir}/err"
    fi

    return 0
}

# t_oracle_fires <label> <expected-substring> <name> -- <command...>
t_oracle_fires()
{
    local _lab _want _name _dir _rc

    _lab=$1
    shift
    _want=$1
    shift
    _name=$1
    shift
    if [ "${1:-}" = "--" ]; then
        shift
    else
        t_not_ok "${_name}"
        t_diag "t_oracle_fires: missing '--' before the command"
        return 0
    fi

    _dir=$( t_tmpdir )
    "$@" > "${_dir}/out" 2> "${_dir}/err"
    _rc=$?

    if [ "${_rc}" -ne 0 ] &&
        grep -q "^oracle FIRED ${_lab}: .*${_want}" "${_dir}/out"; then
        t_ok "${_name}"
    else
        t_not_ok "${_name}"
        t_diag "want: rc non-zero and 'oracle FIRED ${_lab}: ...${_want}...'"
        t_diag "rc: ${_rc}"
        sed -e 's/^/# out: /' "${_dir}/out"
        sed -e 's/^/# err: /' "${_dir}/err"
    fi

    return 0
}

# t_oracle_ok <label> <name> -- <command...>
t_oracle_ok()
{
    local _lab _name _dir _rc

    _lab=$1
    shift
    _name=$1
    shift
    if [ "${1:-}" = "--" ]; then
        shift
    else
        t_not_ok "${_name}"
        t_diag "t_oracle_ok: missing '--' before the command"
        return 0
    fi

    _dir=$( t_tmpdir )
    "$@" > "${_dir}/out" 2> "${_dir}/err"
    _rc=$?

    if [ "${_rc}" -eq 0 ] && grep -q "^oracle ok ${_lab}\$" "${_dir}/out"; then
        t_ok "${_name}"
    else
        t_not_ok "${_name}"
        t_diag "want: rc 0 and 'oracle ok ${_lab}'"
        t_diag "rc: ${_rc}"
        sed -e 's/^/# out: /' "${_dir}/out"
        sed -e 's/^/# err: /' "${_dir}/err"
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Invariant 1 -- no guest is active on two nodes
# ---------------------------------------------------------------------------

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
t_quiet 1 "invariant 1: a coherent world is quiet" -- inv_1 "${M}" "${O}"

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
row "${O}/running" ghost01 bravo 1
t_fires 1 "invariant 1: ghost01 running on two nodes" -- inv_1 "${M}" "${O}"

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
row "${O}/placement" bravo ghost01 active
row "${O}/placement" charlie ghost01 active
t_fires 1 "invariant 1: two nodes claim ghost01 active" -- inv_1 "${M}" "${O}"

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
row "${O}/placement" bravo ghost01 active
row "${O}/placement" charlie ghost01 held
t_quiet 1 "invariant 1: an active claim beside a held one is not a split" \
    -- inv_1 "${M}" "${O}"

# THE CORPSE'S CLAIM (D-150). A node the ladder's rung 4 has just fenced is
# off, and its placement file goes on saying 'active' for the estate it was
# running -- nobody can rewrite a disk that is not powered. The record is kept
# on purpose (invariant 2 clause C needs it), so the invariant that asks who is
# running the guest NOW has to ignore it. Without this, the split-brain
# invariant fires on the exact sequence seance exists to make safe.
W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
: > "${M}/nodes"
row "${M}/nodes" alpha dead
row "${M}/nodes" bravo alive
row "${M}/nodes" charlie alive
row "${O}/placement" alpha ghost01 active
row "${O}/placement" bravo ghost01 active
t_quiet 1 "invariant 1: a fenced node's stale claim is not a second claimant" \
    -- inv_1 "${M}" "${O}"

# And the same shape with the node ALIVE, which is what a promotion that
# skipped its fence leaves behind -- it must still fire, or the narrowing above
# would have taken the invariant with it.
W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
row "${O}/placement" alpha ghost01 active
row "${O}/placement" bravo ghost01 active
t_fires 1 "invariant 1: two LIVE nodes claiming one guest still fires" \
    -- inv_1 "${M}" "${O}"

# An isolated node is alive, and an isolated node claiming a guest a live heir
# also claims is the unfenced promotion the rediscovery battery reverts.
W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
: > "${M}/nodes"
row "${M}/nodes" alpha isolated
row "${M}/nodes" bravo alive
row "${M}/nodes" charlie alive
row "${O}/placement" alpha ghost01 active
row "${O}/placement" bravo ghost01 active
t_fires 1 "invariant 1: an ISOLATED node still counts as a claimant" \
    -- inv_1 "${M}" "${O}"

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
rm -f "${O}/running"
t_fires 1 "invariant 1: a missing observation file fires, it does not pass" \
    -- inv_1 "${M}" "${O}"

# And the guard itself, not only its consequence: without this row an
# inv_state_file that returned 0 for an absent file would still be caught by
# awk failing on the missing path, so the guard would be untested.
t_rc 2 "inv_state_file refuses a state file that is not there" \
    -- inv_state_file "$( t_tmpdir )" running

# ---------------------------------------------------------------------------
# Invariant 2 -- every promotion has evidence, and the logs parse
# ---------------------------------------------------------------------------

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
t_quiet 2 "invariant 2: a world with no promotions is quiet" \
    -- inv_2 "${M}" "${O}"

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
row "${O}/placement" bravo ghost01 active
row "${O}/records" bravo ghost01 alpha bravo "${TS_NOW}" fence:jailfence
t_quiet 2 "invariant 2: a promotion with a confirmed fence is quiet" \
    -- inv_2 "${M}" "${O}"

# No placement row: a stale record about a move that is not in force still has
# to carry evidence, and testing it with the guest also placed away from home
# would let the away-from-home clause satisfy this row instead.
W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
row "${O}/records" bravo ghost01 alpha bravo "${TS_NOW}" "someone-said-so"
t_fires 2 "invariant 2: a record with unrecognised evidence" \
    -- inv_2 "${M}" "${O}"

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
row "${O}/records" bravo ghost01 alpha bravo fence:jailfence
t_fires 2 "invariant 2: a succession log that does not parse" \
    -- inv_2 "${M}" "${O}"

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
row "${O}/placement" bravo ghost01 active
t_fires 2 "invariant 2: a placement away from home with no record at all" \
    -- inv_2 "${M}" "${O}"

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
row "${O}/placement" bravo ghost01 active
row "${O}/records" bravo ghost01 alpha bravo "${TS_NOW}" failback
t_fires 2 "invariant 2: a promotion away from home labelled as a failback" \
    -- inv_2 "${M}" "${O}"

# A return home needs failback evidence of its own: prev has ghost01 promoted
# to bravo with a fence, cur has it back at alpha carrying only that record.
W=$( world "${TS_NOW}" )
M=${W% *}
P=${W#* }
row "${P}/placement" bravo ghost01 active
row "${P}/records" bravo ghost01 alpha bravo "${TS_NOW}" fence:jailfence
W=$( world "${TS_NOW}" )
O=${W#* }
row "${O}/records" bravo ghost01 alpha bravo "${TS_NOW}" fence:jailfence
t_fires 2 "invariant 2: a guest home again with no failback record" \
    -- inv_2 "${M}" "${O}" "${P}"

row "${O}/records" alpha ghost01 bravo alpha "${TS_NEW}" failback
t_quiet 2 "invariant 2: a failback with its record is quiet" \
    -- inv_2 "${M}" "${O}" "${P}"

# ---------------------------------------------------------------------------
# Invariant 3 -- lineage is monotonic
# ---------------------------------------------------------------------------

W=$( world "${TS_NOW}" )
M=${W% *}
P=${W#* }
W=$( world "${TS_NEW}" )
O=${W#* }
t_quiet 3 "invariant 3: lineage moving forward is quiet" \
    -- inv_3 "${M}" "${O}" "${P}"

# The model's lineage is emptied for the three rows below so that only the
# state-to-state comparison can fire: with it left in place the model clause
# would satisfy them too, and blinding the transition clause would go
# unnoticed.
W=$( world "${TS_NOW}" )
M=${W% *}
P=${W#* }
: > "${M}/lineage"
W=$( world "${TS_OLD}" )
O=${W#* }
t_fires 3 "invariant 3: a replica whose newest timestamp went backwards" \
    -- inv_3 "${M}" "${O}" "${P}"

W=$( world "${TS_NOW}" )
M=${W% *}
P=${W#* }
: > "${M}/lineage"
W=$( world "${TS_NOW}" )
O=${W#* }
: > "${O}/snapshots"
t_fires 3 "invariant 3: a replica whose snapshots vanished entirely" \
    -- inv_3 "${M}" "${O}" "${P}"

# A foreign snapshot with a later-sorting name must not mask the regression:
# the checker parses seance names and nothing else. Only bravo's copy of
# ghost01 is rolled back, so this row fires on that pair alone.
W=$( world "${TS_NOW}" )
M=${W% *}
P=${W#* }
: > "${M}/lineage"
W=$( world "${TS_NOW}" )
O=${W#* }
grep -v "^bravo${TAB}ghost01${TAB}" "${O}/snapshots" > "${O}/snapshots.new"
mv "${O}/snapshots.new" "${O}/snapshots"
row "${O}/snapshots" bravo ghost01 "seance-alpha-${TS_OLD}"
row "${O}/snapshots" bravo ghost01 "zrepl-20991231T235959Z"
t_fires 3 "invariant 3: a newer foreign snapshot does not mask a regression" \
    -- inv_3 "${M}" "${O}" "${P}"

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
: > "${M}/lineage"
row "${M}/lineage" ghost01 bravo "${TS_NEW}"
t_fires 3 "invariant 3: the model believes in a snapshot that is not there" \
    -- inv_3 "${M}" "${O}"

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
: > "${M}/lineage"
row "${M}/lineage" ghost01 bravo "yesterday"
t_fires 3 "invariant 3: a model timestamp that is not a seance timestamp" \
    -- inv_3 "${M}" "${O}"

# ---------------------------------------------------------------------------
# Invariant 4 -- no data-bearing dataset is ever destroyed by seance
# ---------------------------------------------------------------------------

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
t_quiet 4 "invariant 4: with no previous state nothing can have been destroyed" \
    -- inv_4 "${M}" "${O}"

W=$( world "${TS_NOW}" )
M=${W% *}
P=${W#* }
W=$( world "${TS_NEW}" )
O=${W#* }
t_quiet 4 "invariant 4: an unchanged dataset set is quiet" \
    -- inv_4 "${M}" "${O}" "${P}"

W=$( world "${TS_NOW}" )
M=${W% *}
P=${W#* }
W=$( world "${TS_NOW}" )
O=${W#* }
grep -v 'pool/seance/bravo/ghost01' "${O}/datasets" > "${O}/datasets.new"
mv "${O}/datasets.new" "${O}/datasets"
t_fires 4 "invariant 4: a dataset that was there and is not" \
    -- inv_4 "${M}" "${O}" "${P}"

# ---------------------------------------------------------------------------
# Invariant 4a -- no replica is ever mounted
# ---------------------------------------------------------------------------

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
t_quiet 4a "invariant 4a: inert replicas beside mounted homes are quiet" \
    -- inv_4a "${M}" "${O}"

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
set_prop "${O}" bravo ghost01 canmount on
t_fires 4a "invariant 4a: a replica with canmount=on" -- inv_4a "${M}" "${O}"

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
set_prop "${O}" bravo ghost01 mountpoint /mnt/handmounted
t_fires 4a "invariant 4a: a replica with a real mountpoint" \
    -- inv_4a "${M}" "${O}"

W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
set_prop "${O}" bravo ghost01 canmount on
row "${M}/refused" ghost01 bravo
t_quiet 4a "invariant 4a: a pair seance refused is exempt until it is repaired" \
    -- inv_4a "${M}" "${O}"

# The node actually running a guest is not a replica of it: after a promotion
# to bravo, bravo's copy is mounted and must be.
W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
row "${O}/placement" bravo ghost01 active
: > "${O}/props"
row "${O}/props" bravo ghost01 canmount on
row "${O}/props" bravo ghost01 mountpoint /estate/ghost01
row "${O}/props" alpha ghost01 canmount noauto
row "${O}/props" alpha ghost01 mountpoint none
t_quiet 4a "invariant 4a: the node authorised to run a guest may mount it" \
    -- inv_4a "${M}" "${O}"

# AND WHEN A SECOND NODE ALSO CLAIMS IT (D-150). alpha's home claim is still
# there -- a fenced node's record outlives it -- so the effective placement is
# alpha and bravo, which has just promoted, was read as holding a shadow mount.
# One fact, and it is invariant 1's to report; 4a must not report it a second
# time as something else.
W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
row "${O}/placement" alpha ghost01 active
row "${O}/placement" bravo ghost01 active
: > "${O}/props"
row "${O}/props" bravo ghost01 canmount on
row "${O}/props" bravo ghost01 mountpoint /estate/ghost01
t_quiet 4a "invariant 4a: a claimant is never a replica, even beside another claim" \
    -- inv_4a "${M}" "${O}"

# The narrowing goes no further than a CLAIM: a node holding a mounted copy of
# a guest it does not claim is the hand-mount, and the August defect.
W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
row "${O}/placement" alpha ghost01 active
: > "${O}/props"
row "${O}/props" charlie ghost01 canmount on
row "${O}/props" charlie ghost01 mountpoint /estate/ghost01
t_fires 4a "invariant 4a: a node with no claim and a mounted copy still fires" \
    -- inv_4a "${M}" "${O}"

# ---------------------------------------------------------------------------
# Invariant 5 / the cheap oracle
# ---------------------------------------------------------------------------

t_oracle_ok version "oracle: a clean 'seance version' run" \
    -- oracle_run version sh "${T_ROOT}/bin/seance" version

t_oracle_ok config "oracle: a clean 'seance config --check' run" \
    -- oracle_run config env \
        "SEANCE_CONF=${T_ROOT}/tests/vectors/config/01-minimal.conf" \
        sh "${T_ROOT}/bin/seance" config --check

t_oracle_fires rc3 'exit status 3' "oracle: an exit status outside 0/1/2" \
    -- oracle_run rc3 sh -c 'echo "done: nothing to do"; exit 3'

t_oracle_fires noverdict 'no verdict' "oracle: a last stdout line that is not a verdict" \
    -- oracle_run noverdict sh -c 'echo "  a continuation line"'

t_oracle_fires silent 'wrote nothing to stdout' "oracle: a verb that says nothing at all" \
    -- oracle_run silent sh -c 'exit 0'

# shellcheck disable=SC2016
#   The '${...}' is deliberately unexpanded: it is source text handed to an
#   inner 'sh -u' so that the inner shell is the one that trips over it.
t_oracle_fires setu 'parameter not set' "oracle: set -u tripped on stderr" \
    -- oracle_run setu sh -u -c 'echo PASS; echo "${SEANCE_NOT_A_REAL_VARIABLE}"'

SEANCE_SIM_STEP_TIMEOUT=2
HANG_T0=$( date +%s )
t_oracle_fires hang 'hung: no verdict within 2s' "oracle: a verb that hangs past the step timeout" \
    -- oracle_run hang sleep 10
HANG_T1=$( date +%s )
SEANCE_SIM_STEP_TIMEOUT=5

# The timeout must be *enforced*, not merely measured after the fact. A ten
# second sleep bounded at two must cost about two seconds; four is the slack
# for a loaded machine, and it is still nowhere near ten. Without this row an
# oracle that dropped timeout(1) and only compared elapsed times would still
# report the hang -- having let a wedged verb take the whole session first.
if [ "$(( HANG_T1 - HANG_T0 ))" -le 4 ]; then
    t_ok "oracle: the step timeout is enforced, not just measured"
else
    t_not_ok "oracle: the step timeout is enforced, not just measured"
    t_diag "a 10s command bounded at 2s took $(( HANG_T1 - HANG_T0 ))s"
fi

# The capture directory is the evidence a failing seed leaves behind, so its
# completeness is asserted rather than assumed.
oracle_run capture sh -c 'echo "PASS"' > /dev/null 2>&1
CAP=${ORACLE_LAST_DIR}
MISSING=""
for f in label cmd rc elapsed timeout stdout stderr; do
    [ -f "${CAP}/${f}" ] || MISSING="${MISSING} ${f}"
done
t_is "${MISSING}" "" "oracle: the capture directory holds all seven files"

# An incomplete capture is a contract error (rc 2), never an absence of
# evidence: a step whose rc file never got written must not read as a step
# whose command exited 0.
INCOMPLETE=$( t_tmpdir )/cap
mkdir -p "${INCOMPLETE}"
cp "${CAP}"/* "${INCOMPLETE}/"
rm -f "${INCOMPLETE}/rc"
FAULTS=$( oracle_faults "${INCOMPLETE}" )
FAULTS_RC=$?
if [ "${FAULTS_RC}" -eq 2 ] &&
    printf '%s\n' "${FAULTS}" | grep -q 'capture is incomplete'; then
    t_ok "oracle: an incomplete capture is a contract error, not a pass"
else
    t_not_ok "oracle: an incomplete capture is a contract error, not a pass"
    t_diag "rc: ${FAULTS_RC}"
    printf '%s\n' "${FAULTS}" | sed -e 's/^/# out: /'
fi

# ---------------------------------------------------------------------------
# inv_5 and inv_check_all
# ---------------------------------------------------------------------------

oracle_run badrc sh -c 'echo "done: nothing"; exit 3' > /dev/null 2>&1
BADCAP=${ORACLE_LAST_DIR}
t_fires 5 "invariant 5: inv_5 fires on a captured bad invocation" \
    -- inv_5 "${BADCAP}"

oracle_run goodrc sh -c 'echo "PASS"' > /dev/null 2>&1
GOODCAP=${ORACLE_LAST_DIR}
t_quiet 5 "invariant 5: inv_5 is quiet on a captured clean invocation" \
    -- inv_5 "${GOODCAP}"

# The negative control: a coherent pair of states, an invocation that behaved,
# and nothing may fire.
W=$( world "${TS_NOW}" )
M=${W% *}
P=${W#* }
W=$( world "${TS_NEW}" )
O=${W#* }
printf '%s\n' "${GOODCAP}" > "${O}/invocations"
CTL=$( t_tmpdir )
inv_check_all "${M}" "${O}" "${P}" > "${CTL}/out" 2> "${CTL}/err"
CTL_RC=$?
t_is "${CTL_RC}" 0 "negative control: a coherent world passes every invariant"
t_unlike "$( cat "${CTL}/out" )" 'FIRED' \
    "negative control: nothing fires on a coherent world"
t_is "$( grep -c '^invariant ' "${CTL}/out" )" 6 \
    "negative control: all six invariants reported (1, 2, 3, 4, 4a, 5)"

# And the positive: one broken thing anywhere makes inv_check_all say so.
W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
row "${O}/running" ghost01 bravo 1
t_fires 1 "inv_check_all: rc 1 and a FIRED line when an invariant fires" \
    -- inv_check_all "${M}" "${O}"

# A step that forgot to record its invocations is a contract error, not a
# silently empty list.
W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
rm -f "${O}/invocations"
t_fires 5 "inv_check_all: a missing invocation list fires invariant 5" \
    -- inv_check_all "${M}" "${O}"

# An invocation that fired is carried into the step's verdict.
W=$( world "${TS_NOW}" )
M=${W% *}
O=${W#* }
printf '%s\n' "${BADCAP}" > "${O}/invocations"
t_fires 5 "inv_check_all: a bad invocation in the step fires invariant 5" \
    -- inv_check_all "${M}" "${O}"

# ---------------------------------------------------------------------------
# The assertion that guards the others
# ---------------------------------------------------------------------------

t_is "$( sort -u "${SEEN}" | tr '\n' ' ' )" "1 2 3 4 4a 5 " \
    "every invariant was observed firing at least once"

t_done
