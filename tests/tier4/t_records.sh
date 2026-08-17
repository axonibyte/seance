#!/bin/sh
# Tier 4 -- the two records M2 writes, against corruption and against each other.
#
# `succession.log` and `placement` are the whole of what a promotion leaves
# behind (D-44 item 6). One says what happened; the other says what is true
# now, and it is the one the boot gate reads before it decides whether a guest
# may start. Two things can go wrong with a record: it can be written badly,
# and it can be written at the same time as another one.
#
# WRITTEN BADLY. `placement_local` used to read the file with
# `awk 'NF >= 2'` -- every line that did not fit the format was dropped in
# silence. The line most likely not to fit is a torn one, the guest name
# written and the home not, and a dropped record is a guest this node is
# hosting away from home that it no longer knows it is hosting: `status` calls
# it home, `gate --release` releases it because nothing claims it, and it
# starts here while it runs there. Same class as D-88 and D-96, same answer:
# evidence that cannot be read is not evidence of absence.
#
# WRITTEN AT THE SAME TIME. Two `seance promote` runs on one node -- two dead
# nodes, or an operator and a script -- both claim a guest. `placement_set` was
# a read-modify-write with no lock, so the second one's rename put back a file
# that predated the first one's claim. Measured before the fix: twenty
# concurrent claims left ONE record. `promote_record` is an append of one short
# line and needs no lock, which this file asserts rather than assumes -- an
# append that turned out to interleave would be a corrupt audit trail, and the
# only way to know is to run it.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SEANCE_ROOT=${T_ROOT}
export SEANCE_ROOT

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/common.subr
. "${T_ROOT}/lib/common.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/policy.subr
. "${T_ROOT}/lib/policy.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/conf.subr
. "${T_ROOT}/lib/conf.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/transport.subr
. "${T_ROOT}/lib/transport.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/notify.subr
. "${T_ROOT}/lib/notify.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/zfs.subr
. "${T_ROOT}/lib/zfs.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/lineage.subr
. "${T_ROOT}/lib/lineage.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/repl.subr
. "${T_ROOT}/lib/repl.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/status.subr
. "${T_ROOT}/lib/status.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/gate.subr
. "${T_ROOT}/lib/gate.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/promote.subr
. "${T_ROOT}/lib/promote.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/failback.subr
. "${T_ROOT}/lib/failback.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../mock-adapter.subr
. "${T_ROOT}/tests/mock-adapter.subr"

DIR=$( t_tmpdir )
SEANCE_STATE_DIR="${DIR}/state"
export SEANCE_STATE_DIR
mkdir -p "${SEANCE_STATE_DIR}"

# The temporary-directory registry, wired to the harness's cleanup rather than
# to seance's own, for the reason t_ladder.sh gives: seance_tmp_init installs a
# trap on EXIT and would replace the one the harness set.
SEANCE_TMP_REGISTRY=$( t_tmpdir )/registry
: > "${SEANCE_TMP_REGISTRY}"
export SEANCE_TMP_REGISTRY
t_at_exit 'seance_tmp_cleanup'

# Enough of a fleet for the verbs that ask who this node is. The mock adapter
# answers `alpha`, and alpha is in the file.
CONF="${DIR}/seance.conf"
cat > "${CONF}" <<'EOF'
node_alpha_nodename=alpha
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
EOF
conf_load "${CONF}" || { echo "the fixture configuration did not load" >&2; exit 2; }

SEANCE_MOCK_NODE=alpha
SEANCE_MOCK_WORKDIR="${DIR}/workdir"
SEANCE_MOCK_LOG="${DIR}/mock.log"
export SEANCE_MOCK_NODE SEANCE_MOCK_WORKDIR SEANCE_MOCK_LOG
mkdir -p "${SEANCE_MOCK_WORKDIR}"

PFILE="${SEANCE_STATE_DIR}/placement"
SFILE="${SEANCE_STATE_DIR}/succession.log"

TAB=$( printf '\t.' )
TAB=${TAB%.}

t_plan 25

# ---------------------------------------------------------------------------
# A placement file with hostile lines in it
# ---------------------------------------------------------------------------

# The good file first, so that what follows is measured against a known answer.
printf 'web01\talpha\ndb01\tcharlie\n' > "${PFILE}"
t_is "$( placement_local | tr '\n' ' ' )" "web01	alpha db01	charlie " \
    "a well-formed placement file reads back as its records"
t_is "$( placement_home web01 )" "alpha" "and a guest's home can be read out of it"
t_rc 1 "a guest it does not claim is rc 1 -- a real answer, and a different one" \
    -- placement_home nosuchguest

# --- the torn line: the guest, and then the crash --------------------------
printf 'web01\talpha\ndb01\n' > "${PFILE}"
t_rc 1 "a record with only a guest name fails the read" -- placement_local
err=$( placement_local 2>&1 >/dev/null )
t_like "${err}" '^  line 2: db01$' "and the line is quoted, by number"
t_rc 2 "and placement_home says CANNOT TELL (2), not 'no claim' (1)" \
    -- placement_home web01

# --- a field too many ------------------------------------------------------
printf 'web01\talpha\tstale-comment\n' > "${PFILE}"
t_rc 1 "a record with a third field fails the read: the format is two fields" \
    -- placement_local

# --- CRLF, which is invisible on screen ------------------------------------
printf 'web01\talpha\r\n' > "${PFILE}"
t_rc 1 "a carriage return makes the home a node key nothing will match, so it fails the read" \
    -- placement_local

# --- whitespace where a name should be -------------------------------------
printf ' web01\talpha\n' > "${PFILE}"
t_rc 1 "a leading space is part of the guest name, and no guest has one" \
    -- placement_local

printf 'web01\talpha\n\n' > "${PFILE}"
t_rc 1 "an empty line in a state file is a torn write, not a paragraph break" \
    -- placement_local

printf 'WEB01\talpha\n' > "${PFILE}"
t_rc 1 "a guest name seance would never have written fails the read" \
    -- placement_local

# --- and what the verbs do with it -----------------------------------------
#
# `placement`, `gate` and `status` all read this file, and none of them may
# read a fault as an absence.

printf 'web01\talpha\ndb01\n' > "${PFILE}"

t_rc 1 "the placement verb fails on a file it cannot read" -- placement_report 0
out=$( placement_report 0 2>/dev/null )
t_unlike "${out}" '^placement\t' \
    "and prints no records at all: half a placement is not a placement"
t_unlike "${out}" '^placement: [0-9]' \
    "and no verdict line either, so a peer reading it counts this node as silent (D-96)"

t_rc 1 "gate_home_guests fails rather than calling every guest its own" \
    -- gate_home_guests

# The failback's own reader: closing a failback needs to know whether this node
# claims the guest, and "cannot tell" is not "no".
t_like "$( failback_assist web01 release 2>&1 )" 'cannot read its own placement' \
    "failback-assist release refuses on an unreadable placement instead of closing the record"

# ---------------------------------------------------------------------------
# Two writers at once
# ---------------------------------------------------------------------------

N=20

rm -f "${PFILE}"
i=0
while [ "${i}" -lt "${N}" ]; do
    placement_set "g${i}" alpha &
    i=$(( i + 1 ))
done
wait

t_is "$( awk 'END { print NR }' "${PFILE}" )" "${N}" \
    "${N} guests claimed at once leave ${N} records: no claim is lost to another's rename"
t_is "$( awk -F "${TAB}" 'NF != 2 { n++ } END { print n + 0 }' "${PFILE}" )" "0" \
    "and every one of them is a whole record"
t_is "$( LC_ALL=C sort "${PFILE}" | uniq -d | wc -l | tr -d ' ' )" "0" \
    "and no record is written twice"

# The same guest, from every writer at once: one guest, one record, always.
rm -f "${PFILE}"
i=0
while [ "${i}" -lt "${N}" ]; do
    placement_set web01 "alpha" &
    i=$(( i + 1 ))
done
wait
t_is "$( awk 'END { print NR }' "${PFILE}" )" "1" \
    "one guest claimed ${N} times at once is still one record"

# Clearing one while another is claimed: the survivor survives.
rm -f "${PFILE}"
placement_set web01 alpha
placement_set db01 charlie
placement_clear web01 &
placement_set arc01 delta &
wait
t_is "$( LC_ALL=C sort "${PFILE}" | tr '\n' ' ' )" "arc01	delta db01	charlie " \
    "a clear and a claim at the same time leave both their intended effects"

# --- the append-only record ------------------------------------------------
#
# promote_record is one printf of one short line onto a file opened O_APPEND,
# which is atomic; the lock the placement file needs is exactly what this does
# not need. Asserted, not assumed.

rm -f "${SFILE}"
NOW=$( date -u +%s )
i=0
while [ "${i}" -lt "${N}" ]; do
    promote_record "g${i}" alpha bravo "${NOW}" fence:mock &
    i=$(( i + 1 ))
done
wait

t_is "$( awk 'END { print NR }' "${SFILE}" )" "${N}" \
    "${N} succession records appended at once are ${N} lines"
t_is "$( awk -F "${TAB}" 'NF != 5 { n++ } END { print n + 0 }' "${SFILE}" )" "0" \
    "and not one of them is torn: every line has its five fields"
t_is "$( awk -F "${TAB}" '{ print $1 }' "${SFILE}" | LC_ALL=C sort | uniq | wc -l |
    tr -d ' ' )" "${N}" \
    "and each guest appears exactly once: an append is not a read-modify-write"
t_like "$( head -1 "${SFILE}" )" \
    "^g[0-9]+	alpha	bravo	[0-9]{8}T[0-9]{6}Z	fence:mock\$" \
    "and the shape of a record survived the crowd"

t_done
