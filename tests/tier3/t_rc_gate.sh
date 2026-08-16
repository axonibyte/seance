#!/bin/sh
# Tier 3 -- the boot gate's rc(8) unit, read as data (TESTING.md §4).
#
# rc.d/seance_gate has exactly one property that cannot be tested without
# booting a node, and it is the one the whole gate depends on: it must be
# ordered BEFORE the platform's daemon, because the platform's autostart is not
# an rc(8) unit of its own and is started from inside that daemon's prestart.
# Lose the BEFORE line and the gate still runs, still holds the right guests,
# and does it after the estate is already up.
#
# So it is asserted the cheapest way there is: source as data. This tier cannot
# prove the ordering works; it can prove the ordering is still declared, which
# is the part that rots.
#
# EVIDENCE for what is asserted here, read from the installed CBSD 15.0.9 tree:
#
#   rc.d/jails-astart has NO PROVIDE line and is never run by rc(8);
#   rc.d/cbsdd's cbsdd_prestart() ends with
#       ${miscdir}/daemonize ${CIX_BIN} ${rcddir}/jails-astart start
#   and its own header is
#       # PROVIDE: cbsdd
#       # REQUIRE: LOGIN FILESYSTEMS cleanvar sshd
#       # KEYWORD: shutdown
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

UNIT="${T_ROOT}/rc.d/seance_gate"

# directive <file> <name>  -- the value of an rc(8) header directive.
directive()
{
    sed -n -e "s/^# *$2: *//p" "$1" | head -1
}

t_plan 11

t_rc 0 "rc.d/seance_gate exists and is executable" -- test -x "${UNIT}"

t_is "$( directive "${UNIT}" PROVIDE )" "seance_gate" \
    "it provides seance_gate"

# THE ONE THAT MATTERS. The platform's autostart is not an rc(8) unit: it is
# started from inside the daemon's prestart, so BEFORE the daemon is the only
# ordering that gets in front of the estate coming up.
t_is "$( directive "${UNIT}" BEFORE )" "cbsdd" \
    "it is ordered BEFORE the platform's daemon, which is what starts the estate"

REQUIRE=$( directive "${UNIT}" REQUIRE )
t_like "${REQUIRE}" '(^| )FILESYSTEMS( |$)' \
    "it requires FILESYSTEMS: the state directory has to be there to read"
t_like "${REQUIRE}" '(^| )NETWORKING( |$)' \
    "and NETWORKING, because 'no peer answered' must mean the peers and not the boot order"

t_like "$( cat "${UNIT}" )" '^rcvar=seance_gate_enable$' \
    "its rcvar is seance_gate_enable"
t_like "$( cat "${UNIT}" )" 'seance_gate_enable:=NO' \
    "and it is disabled by default: a unit that withheld guests the day it landed would be a surprise"

t_like "$( cat "${UNIT}" )" 'seance_gate_program' \
    "the dispatcher's path can be overridden from rc.conf"
t_like "$( cat "${UNIT}" )" 'modules/seance' \
    "and is otherwise derived from the verb symlink the platform's own initialisation plants"

# Mutation checks, permanent: a guard never observed failing has unmeasured
# value, and the ordering is the thing that rots silently.
scratch=$( t_tmpdir )
grep -v '^# BEFORE:' "${UNIT}" > "${scratch}/no-before"
t_isnt "$( directive "${scratch}/no-before" BEFORE )" "cbsdd" \
    "a unit that has lost its BEFORE line is caught"

sed -e 's/^rcvar=seance_gate_enable$/rcvar=seance_enable/' "${UNIT}" \
    > "${scratch}/renamed"
t_unlike "$( cat "${scratch}/renamed" )" '^rcvar=seance_gate_enable$' \
    "and so is a unit whose rcvar has been renamed out from under rc.conf"

t_done
