#!/bin/sh
# Tier 1 -- `seance setup`'s INTERACTIVE path, driven under a pty.
#
# WHY THIS FILE EXISTS. lib/setup.subr shipped with a header saying the wizard
# was "NOT SMOKE-TESTED -- bsddialog needs a real terminal; there is no
# script(1) harness for it here", and tests/tier3/t_setup_bsddialog_coverage.sh
# stood in for it by reading the call sites as data. Both statements were true
# about the tests and false about the system: script(1) is in the base system,
# `script -q /dev/null <cmd>` gives the command a controlling terminal (so
# setup_require_tty's `[ -t 0 ] && [ -t 2 ]` holds), and bsddialog draws in it
# perfectly well.
#
# The first time the wizard was actually run, at M5, it did not work at all.
# bsddialog(1) documents `--stderr` as the DEFAULT for "print input from user
# interface", and `--stdout` as moving that input to standard output -- the
# ANSWER moves, the DRAWING does not, because it is an ncurses program and
# ncurses draws on stdout. Every screen was `_v=$( bsddialog --stdout ... )`,
# so the command substitution captured the whole ANSI screen with the answer
# appended, and the terminal got nothing. Measured on the workstation:
#
#     setup_ask_cadence  ->  cadence=<1441 bytes of terminal control>
#
# and the node-selection loop, which stops on a BLANK answer, never saw one --
# so the wizard looped for ever, on a blank screen, writing screenfuls of
# escape codes into a configuration file. lib/setup.subr's setup_dialog() is
# the fix and carries the reasoning; this file is the test that would have
# caught it, and it is at tier 1 because it needs no cluster, no CBSD and no
# root -- only a terminal, which script(1) supplies.
#
# HOW THE WIZARD IS DRIVEN. One newline per screen, which takes each dialog's
# default: the welcome and review confirmations say Yes, every inputbox is
# accepted as it stands (they all start EMPTY -- the seed is `setup_get <key>
# ""` and nothing has been set yet), the node- and guest-selection screens
# accept the blank that stops them. The only typed answer is the FIRST
# inputbox, `cadence`, so that "a value typed at a screen reaches the file"
# is asserted rather than assumed. The feeder sends more newlines than there
# are screens on purpose: unread input is discarded when the verb exits, and a
# short feed would hang instead of failing.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SEANCE="${T_ROOT}/bin/seance"
DIR=$( t_tmpdir )

t_plan 14

# ---------------------------------------------------------------------------
# The harness this file rests on, asserted rather than assumed
# ---------------------------------------------------------------------------
#
# Both are base-system programs on FreeBSD, which is the only platform seance
# targets (handoff §5). If either goes away this file must say so loudly: a
# smoke test that silently stops smoking is the shape of the problem it was
# written for.

t_rc 0 "script(1) is present: it is what gives the wizard a terminal" -- \
    command -v script
t_rc 0 "bsddialog(1) is present: it is what the wizard draws with" -- \
    command -v bsddialog

# ---------------------------------------------------------------------------
# No terminal: refuse, do not hang
# ---------------------------------------------------------------------------
#
# The operationally important half. A configuration-management run that forgot
# --non-interactive must get an error, not a process waiting for a keystroke
# nobody will type.

env SEANCE_CONF="${DIR}/none.conf" sh "${SEANCE}" setup --out "${DIR}/never.conf" \
    < /dev/null > "${DIR}/notty.out" 2> "${DIR}/notty.err"
t_is "$?" "2" "setup with no terminal is a contract error"
t_like "$( cat "${DIR}/notty.err" )" 'an interactive terminal is required' \
    "and it names the flag that runs it headless instead"
t_rc 1 "and it wrote nothing" -- test -e "${DIR}/never.conf"

# ---------------------------------------------------------------------------
# The wizard, under a pty
# ---------------------------------------------------------------------------

KEYS="${DIR}/keys"
{
    printf '\n'          # welcome: Yes
    printf '600\n'       # cadence: a typed answer
    i=0
    while [ "${i}" -lt 60 ]; do printf '\n'; i=$(( i + 1 )); done
} > "${KEYS}"

WIZ="${DIR}/wizard.conf"
TERM=${TERM:-xterm}
export TERM

t_run_timeout 120 script -q /dev/null \
    env SEANCE_CONF="${DIR}/none.conf" sh "${SEANCE}" setup \
        --out "${WIZ}" --dump-answers "${DIR}/answers" --allow-invalid \
    < "${KEYS}" > "${DIR}/wizard.log" 2>&1
WIZ_RC=$?

if [ "${WIZ_RC}" -eq 0 ]; then
    t_ok "the wizard runs to completion under a pty and exits 0"
else
    t_not_ok "the wizard runs to completion under a pty and exits 0"
    t_diag "exit ${WIZ_RC} (124 means it never finished: a screen is waiting)"
fi

t_rc 0 "and it wrote the file it was told to write" -- test -r "${WIZ}"

# THE REGRESSION. An answer that is a screen is what shipped; one escape byte
# in the file is the whole defect.
if [ -r "${WIZ}" ] && LC_ALL=C grep -q "$( printf '\033' )" "${WIZ}"; then
    t_not_ok "no terminal control ever reaches the configuration file"
    t_diag "the file carries ESC bytes: bsddialog drew into the answer"
else
    t_ok "no terminal control ever reaches the configuration file"
fi

t_stdout_is "cadence=600" "the value typed at the first screen is in the file" -- \
    grep '^cadence=' "${WIZ}"

# ---------------------------------------------------------------------------
# The interactive path and the headless path write the same file
# ---------------------------------------------------------------------------
#
# design §14: "everything the TUI can do has a non-interactive equivalent".
# The two paths share one renderer by construction (D-139), and this is what
# turns that construction into a measurement: the same answers, one typed at a
# terminal and one given as flags, must produce the same bytes.

HEAD="${DIR}/headless.conf"
env SEANCE_CONF="${DIR}/none.conf" sh "${SEANCE}" setup --non-interactive \
    --set cadence=600 --set auto=1 --out "${HEAD}" --allow-invalid \
    > "${DIR}/headless.log" 2>&1
t_is "$?" "0" "the headless path writes the same answers"

if [ -r "${WIZ}" ] && [ -r "${HEAD}" ]; then
    t_is "$( cat "${WIZ}" )" "$( cat "${HEAD}" )" \
        "and the two files are byte-identical: one renderer, two front ends"
else
    t_not_ok "and the two files are byte-identical: one renderer, two front ends"
fi

# The answers the wizard recorded are a config file in their own right (D-139:
# the answer key IS the config key), so replaying them must land in the same
# place a third time.
REPLAY="${DIR}/replay.conf"
env SEANCE_CONF="${DIR}/none.conf" sh "${SEANCE}" setup --non-interactive \
    --answers "${DIR}/answers" --out "${REPLAY}" --allow-invalid \
    > "${DIR}/replay.log" 2>&1
t_is "$?" "0" "the wizard's --dump-answers file replays headlessly"
if [ -r "${REPLAY}" ] && [ -r "${WIZ}" ]; then
    t_is "$( cat "${REPLAY}" )" "$( cat "${WIZ}" )" \
        "and produces the configuration the wizard wrote"
else
    t_not_ok "and produces the configuration the wizard wrote"
fi

# The yesno screens answered too, and their answer is a value rather than a
# default that would have been written anyway: `auto` has no entry in the file
# unless a screen decided it.
t_stdout_is "auto=1" "a yesno screen's answer reaches the file as a config key" -- \
    grep '^auto=' "${WIZ}"

t_done
