#!/bin/sh
# Tier 1 -- the cadence gate, in both directions (D-141, ruled on in D-152).
#
# `repl` skips a guest whose newest lag record is younger than that guest's
# cadence (D-61). The record carries the tick's own epoch, so the gate is
# arithmetic on two clocks: the record's and this node's. One of them can move.
#
# THE DEFECT THIS FILE WOULD HAVE CAUGHT, found by the tier-7 simulator and
# recorded as D-141: on a node whose clock has jumped BACKWARDS -- ntp stepping
# after a long outage, a hypervisor restoring a paused guest, a BIOS clock read
# wrong at boot -- every guest is "not due" until wall time has caught up with a
# record written in what is now the future. Measured there: a skew of -180 s
# against a cadence of 60 s cost three consecutive ticks, and the only sign was
# the `skipped` count in a verdict line that reads exactly like a healthy tick
# with the gate doing its job:
#
#     repl: 1 guests x 0 pairs, 0 ok, 0 failed, 1 skipped, 0 in progress
#
# The direction is safe -- nothing is destroyed and nothing is promoted -- and
# that is what makes it expensive: a fleet whose clock stepped back an hour
# would replicate nothing for an hour and page nobody.
#
# The fix and its boundary: a record in the future by MORE than
# `skew_tolerance` is due, with a warning; a record in the future by less than
# that is ordinary jitter between two machines and the gate holds. The
# tolerance is the line this project already draws between the two (D-38's
# clamp applies the same rule inside `status`), so the gate borrows it rather
# than inventing a second number.
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

WORK=$( t_tmpdir )
SEANCE_STATE_DIR="${WORK}/state"
export SEANCE_STATE_DIR
mkdir -p "${SEANCE_STATE_DIR}"

# A syslog that is a file, so that "it warned" is an assertion rather than an
# impression -- and so that a test suite does not fill the workstation's log.
SHIM="${WORK}/bin"
mkdir -p "${SHIM}"
cat > "${SHIM}/logger" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${WORLD_DIR}/logger.log"
exit 0
EOF
chmod 0755 "${SHIM}/logger"
PATH="${SHIM}:${PATH}"
export PATH
WORLD_DIR="${WORK}"
export WORLD_DIR

CONF="${WORK}/seance.conf"
cat > "${CONF}" <<'EOF'
cadence=60
staleness_max=180
skew_tolerance=120
node_alpha_nodename=alpha
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_bravo_nodename=bravo
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
EOF

if ! conf_load "${CONF}"; then
    t_plan 1
    t_not_ok "the fixture configuration loads"
    t_done
fi

# NOW is a fixed instant, so that every row below is arithmetic and not a race
# with the clock this test is running against.
NOW=1767225600

# record <epoch>  -- the newest lag record for web01's only pair.
record()
{
    : > "${WORLD_DIR}/logger.log"
    repl_lag_write web01 bravo "20260101T000000Z" "$1" 0
}

# warned  -- what the gate told syslog about this decision, if anything.
# Counted with awk rather than 'grep -c', which exits 1 when it counts zero:
# `grep -c ... || echo 0` then prints its own 0 AND the fallback's, and the row
# that reads it compares two lines against one.
warned()
{
    awk '/in the FUTURE/ { n++ } END { print n + 0 }' \
        "${WORLD_DIR}/logger.log" 2>/dev/null
}

t_plan 14

# ---------------------------------------------------------------------------
# The ordinary direction, unchanged
# ---------------------------------------------------------------------------

record $(( NOW - 61 ))
t_rc 0 "a record older than the cadence is due" \
    -- repl_due web01 alpha "${NOW}"

record $(( NOW - 60 ))
t_rc 0 "a record exactly one cadence old is due: the boundary is inclusive" \
    -- repl_due web01 alpha "${NOW}"

record $(( NOW - 59 ))
t_rc 1 "a record younger than the cadence is not due -- the gate D-61 exists for" \
    -- repl_due web01 alpha "${NOW}"

record "${NOW}"
t_rc 1 "a record written this second is not due" \
    -- repl_due web01 alpha "${NOW}"
t_is "$( warned )" "0" "and says nothing: that is the gate working, not a fault"

# ---------------------------------------------------------------------------
# The record is in the future
# ---------------------------------------------------------------------------

record $(( NOW + 1 ))
t_rc 1 "a record one second in the future is jitter, and the gate holds" \
    -- repl_due web01 alpha "${NOW}"
t_is "$( warned )" "0" "-- silently, because two machines' clocks are never identical"

record $(( NOW + 120 ))
t_rc 1 "a record exactly skew_tolerance in the future is still jitter" \
    -- repl_due web01 alpha "${NOW}"

record $(( NOW + 121 ))
t_rc 0 "a record one second BEYOND skew_tolerance is DUE, not skipped (D-141)" \
    -- repl_due web01 alpha "${NOW}"
t_is "$( warned )" "1" "and it warns, so that a clock that moved is not silent"
record $(( NOW + 121 ))
repl_due web01 alpha "${NOW}" > /dev/null 2>&1
t_like "$( cat "${WORLD_DIR}/logger.log" )" \
    "repl web01: the newest lag record is 121s in the FUTURE" \
    "the warning names the guest and how far ahead the record is"
t_like "$( cat "${WORLD_DIR}/logger.log" )" \
    "record $(( NOW + 121 )), now ${NOW}, skew_tolerance 120s" \
    "and both epochs and the tolerance, so the arithmetic can be checked by hand"

# D-141's OWN SCENARIO, and the assertion that the old behaviour is dead: the
# simulator's node had its clock set back 180 s against a cadence of 60, and
# every tick after it skipped the guest. The record is 180 s ahead of the
# node's `now`; before the fix this returned 1 (not due) three ticks running.
record $(( NOW + 180 ))
t_rc 0 "D-141's own case -- a clock stepped back 180s against a 60s cadence -- replicates" \
    -- repl_due web01 alpha "${NOW}"

# And the tolerance is read from the CONFIGURATION, not compiled in: a fleet
# that tolerates more skew tolerates more of it here too.
CONF2="${WORK}/seance2.conf"
sed -e 's/^skew_tolerance=120$/skew_tolerance=600/' "${CONF}" > "${CONF2}"
conf_load "${CONF2}" > /dev/null 2>&1
record $(( NOW + 180 ))
t_rc 1 "the same record on a fleet whose skew_tolerance is 600s is jitter again" \
    -- repl_due web01 alpha "${NOW}"

t_done
