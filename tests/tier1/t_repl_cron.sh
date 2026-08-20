#!/bin/sh
# Tier 1 -- repl_cron_line: the command cron will actually run.
#
# THE DEFECT THIS FILE EXISTS FOR, found by following docs/INSTALL.md literally
# on a clean guest at M5. The rendered line named the module's plain
# dispatcher:
#
#     */15 * * * * root /usr/local/cbsd/modules/seance.d/bin/seance repl
#
# cron(8) runs a job with PATH, HOME, LOGNAME and SHELL and nothing else, and
# the dispatcher under bin/ learns which node it is on only from the variables
# the module's own verb wrapper exports (D-2). Measured in the reaper guest,
# with exactly the environment cron gives a job:
#
#     env -i PATH=/usr/bin:/bin HOME=/root LOGNAME=root USER=root SHELL=/bin/sh \
#         .../seance.d/bin/seance repl
#     err: no config file: set SEANCE_CONF, or run under CBSD
#     rc=2
#
#     env -i ... /usr/local/bin/cbsd seance repl
#     repl: 3 guests x 4 pairs, ...
#     rc=1
#
# So a freshly installed node replicated NOTHING, for ever, and `seance verify`
# reported the crontab line as correctly installed the whole time -- because
# verify_cron compares the file against this very rendering, so the two agreed
# with each other and with nothing else. That is the shape of every rot this
# project's tier-3 guards exist to catch, arriving one layer below them.
#
# The rendering now asks the adapter (`adapter_fact verb`, D-117), which is the
# one answer to "how does this platform run a seance verb" and is what
# `verify --render devd` has always used for exactly the same reason -- a devd
# action, like a cron job, is executed with an environment nobody set.
#
# The adapter here is a stub of four lines rather than the mock: what is being
# asserted is the SHAPE of the line and the fact that the command comes from
# the seam at all, and a stub makes both readable.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/common.subr
. "${T_ROOT}/lib/common.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/conf.subr
. "${T_ROOT}/lib/conf.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/repl.subr
. "${T_ROOT}/lib/repl.subr"

DIR=$( t_tmpdir )

# The seam, stubbed. VERB is what this "platform" says runs a seance verb;
# FACT_RC lets the file assert what happens when the platform cannot say.
VERB="/usr/local/bin/cbsd seance"
FACT_RC=0

adapter_fact()
{
    [ "${1:-}" = "verb" ] || return 2
    [ "${FACT_RC}" -eq 0 ] || return "${FACT_RC}"
    printf '%s\n' "${VERB}"
}

t_plan 15

# ---------------------------------------------------------------------------
# The shape of the line
# ---------------------------------------------------------------------------

cat > "${DIR}/fleet.conf" <<'EOF'
cadence=900
node_alpha_nodename=alpha
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_bravo_nodename=bravo
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
EOF
conf_load "${DIR}/fleet.conf" || t_diag "fleet.conf failed to load"

LINE=$( repl_cron_line )
t_is "${LINE}" "*/15 * * * * root /usr/local/bin/cbsd seance repl" \
    "the line is a crontab(5) system line at the fleet cadence, running the platform's verb"

t_is "$( printf '%s\n' "${LINE}" | wc -l | tr -d ' ' )" "1" \
    "one line: it is redirected into a crontab fragment as it stands"

# The rot this file is really about. bin/ is where the plain dispatcher lives,
# and the plain dispatcher is exactly what cron cannot run.
t_unlike "${LINE}" '/bin/seance' \
    "and it does NOT name bin/seance, which is the command cron cannot run"

# The user field is what makes it a SYSTEM crontab line rather than a user one
# (crontab(5): five time fields, then a user name, then the command).
t_like "${LINE}" '^\*/[0-9]+ \* \* \* \* root ' \
    "five time fields and then the user, which is what /etc/cron.d wants"

t_like "${LINE}" ' repl$' \
    "and the verb it runs is repl, with no flags: the cadence gate is per guest"

# ---------------------------------------------------------------------------
# The command really does come from the seam
# ---------------------------------------------------------------------------

VERB="/usr/local/seance/seance"
t_is "$( repl_cron_line )" \
    "*/15 * * * * root /usr/local/seance/seance repl" \
    "a platform that answers differently gets a different line: the command is the adapter's fact"

VERB="/usr/local/bin/cbsd seance"

# ---------------------------------------------------------------------------
# A platform that cannot say
# ---------------------------------------------------------------------------
#
# rc 1 and NOTHING on stdout. A crontab line nobody can run is worse than no
# line at all, because `verify --render cron > .../cron.d/seance` would write
# it -- and an empty file there reads as "replication is scheduled" to
# everything except the check that compares it.

FACT_RC=2
t_rc 1 "a platform that cannot name its verb fails the rendering" -- repl_cron_line
t_stdout_is "" "and prints no line at all" -- repl_cron_line
FACT_RC=0

# ---------------------------------------------------------------------------
# The cadence arithmetic, which the change must not have moved
# ---------------------------------------------------------------------------

cat > "${DIR}/perguest.conf" <<'EOF'
cadence=900
guest_db01_cadence=300
node_alpha_nodename=alpha
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_bravo_nodename=bravo
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
EOF
conf_load "${DIR}/perguest.conf" || t_diag "perguest.conf failed to load"
t_like "$( repl_cron_line )" '^\*/5 ' \
    "the shortest per-guest cadence in the fleet is what fires the one line"

cat > "${DIR}/floor.conf" <<'EOF'
cadence=90
node_alpha_nodename=alpha
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_bravo_nodename=bravo
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
EOF
conf_load "${DIR}/floor.conf" || t_diag "floor.conf failed to load"
t_like "$( repl_cron_line )" '^\*/1 ' \
    "a cadence under two minutes still renders whole minutes, floored at one"

# ---------------------------------------------------------------------------
# It is a pure function of the configuration and the platform
# ---------------------------------------------------------------------------

A=$( repl_cron_line )
B=$( repl_cron_line )
t_is "${A}" "${B}" "the rendering is byte-stable across two calls"

TZ="Pacific/Chatham"
LC_ALL="C"
export TZ LC_ALL
C=$( repl_cron_line )
unset TZ LC_ALL
t_is "${A}" "${C}" "and does not move with TZ or the locale"

# ---------------------------------------------------------------------------
# The documents say the same thing
# ---------------------------------------------------------------------------
#
# Source-as-data, here rather than in tier 3, because the thing being checked
# is this function's own output shape: a document that shows an operator a
# crontab line naming bin/seance is showing them the defect.

for doc in docs/INSTALL.md docs/repl-wire.md README.md; do
    if grep -q '^\*\?[/0-9].*root .*bin/seance repl' "${T_ROOT}/${doc}"; then
        t_not_ok "${doc} does not show a crontab line running bin/seance"
        grep -n 'bin/seance repl' "${T_ROOT}/${doc}" | sed -e 's/^/# /'
    else
        t_ok "${doc} does not show a crontab line running bin/seance"
    fi
done

t_done
