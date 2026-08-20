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

t_plan 20

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
    "the command's path can be overridden from rc.conf"
t_like "$( cat "${UNIT}" )" 'modules/seance' \
    "and is otherwise derived from the verb symlink the platform's own initialisation plants"

# ---------------------------------------------------------------------------
# WHAT THE UNIT RUNS, and the M5 defect that makes it worth a guard
#
# The unit resolved that verb symlink and then walked PAST it to bin/seance
# underneath. bin/seance is the plain dispatcher, and it learns which node it
# is on only from what the module's verb wrapper exports (D-2) -- so run from
# rc(8), with no environment at all, it printed
#
#     err: no config file: set SEANCE_CONF, or run under CBSD
#
# and exited 2, and the unit's own diagnostic said THE ESTATE HAS NOT BEEN
# GATED. Every node this unit was installed on booted ungated. Measured in the
# guest, with cbsdd stopped the way boot has not started it yet: the symlink
# answers and the dispatcher does not.
#
# The code line is what is asserted, not the prose: this file's own header and
# the unit's now both NAME bin/seance in comments, in order to say why it is
# not the thing to run.
# ---------------------------------------------------------------------------

CODE=$( grep -v '^[[:space:]]*#' "${UNIT}" )

t_unlike "${CODE}" 'bin/seance' \
    "no code line in the unit names bin/seance: rc(8) cannot run the plain dispatcher"
t_like "${CODE}" 'seance_gate_program="\$\{_link\}"' \
    "what it runs IS the platform's verb symlink, which carries this node's facts"

t_like "${CODE}" '\[ -x "\$\{_link\}" \]' \
    "and it checks the symlink is executable before it believes in it"

# The mutation, which is the defect itself: a unit that resolves the link and
# then runs the dispatcher behind it.
MUT=$( t_tmpdir )/walked-past
sed -e 's|seance_gate_program="${_link}"|seance_gate_program="${_link%/*}/bin/seance"|' \
    "${UNIT}" > "${MUT}"
t_like "$( grep -v '^[[:space:]]*#' "${MUT}" )" 'bin/seance' \
    "a unit that walks past the symlink to bin/seance is caught"

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

# ---------------------------------------------------------------------------
# rcorder(8) itself, on a synthetic rc.d directory
#
# Everything above reads the header and believes it. This runs the program
# rc(8) runs -- rcorder(8), the thing that actually decides the order -- and
# asks where seance_gate lands.
#
# A SYNTHETIC directory, not /etc/rc.d and /usr/local/etc/rc.d: the workstation
# and the guest have different services installed, the answer would depend on
# whichever ones they are, and printing an operator's real service list into a
# public repository's test log is not something a test needs to do. What is
# built here is the smallest world in which the question means anything -- the
# real unit, a cbsdd stub carrying the daemon's REAL header (read from the
# installed 15.0.9 tree, quoted at the top of this file), and one stub per name
# either of them requires.
# ---------------------------------------------------------------------------

RCDIR=$( t_tmpdir )/rc.d
mkdir -p "${RCDIR}"

cp "${UNIT}" "${RCDIR}/seance_gate"

stub()
{
    local _n

    _n=$1
    shift

    {
        printf '#!/bin/sh\n#\n'
        printf '# PROVIDE: %s\n' "${_n}"
        [ $# -gt 0 ] && printf '# REQUIRE: %s\n' "$*"
        printf '#\nexit 0\n'
    } > "${RCDIR}/${_n}"
    chmod 0755 "${RCDIR}/${_n}"
}

# The platform's daemon, with its own header verbatim.
stub cbsdd LOGIN FILESYSTEMS cleanvar sshd
# Everything either unit names, so that rcorder has a complete graph.
stub FILESYSTEMS
stub NETWORKING FILESYSTEMS
stub LOGIN NETWORKING
stub cleanvar FILESYSTEMS
stub sshd NETWORKING

ORDER=$( rcorder "${RCDIR}"/* 2>/dev/null | sed -e "s|^${RCDIR}/||" | tr '\n' ' ' )

t_like "${ORDER}" 'seance_gate.*cbsdd' \
    "rcorder(8) really does put seance_gate ahead of the platform's daemon"
t_like "${ORDER}" 'FILESYSTEMS.*seance_gate' \
    "and behind FILESYSTEMS, so the state directory it reads is mounted"
t_like "${ORDER}" 'NETWORKING.*seance_gate' \
    "and behind NETWORKING, so 'no peer answered' means the peers and not the boot order"

# --- and the mutation, in the world where it is observable ------------------
#
# Taking the BEFORE line out of the unit above does NOT move it in the world
# above: seance_gate requires two names and the daemon requires four, so
# rcorder emits it first anyway. That is the point rather than a nuisance --
# without the BEFORE line the ordering is not wrong, it is UNDECIDED, and it
# comes out right for a reason that has nothing to do with seance. Which is
# exactly the kind of ordering that changes the day somebody adds a REQUIRE to
# either unit.
#
# So the mutation is shown in the smallest world where the edge is the only
# thing deciding: a daemon stub with no requirements of its own, which rcorder
# would otherwise emit first. Its header is deliberately NOT the platform's
# here, and that is stated rather than left to be noticed.
MINDIR=$( t_tmpdir )/rc.d.min
mkdir -p "${MINDIR}"
RCDIR_SAVED=${RCDIR}
RCDIR=${MINDIR}
stub cbsdd
stub FILESYSTEMS
stub NETWORKING
RCDIR=${RCDIR_SAVED}

cp "${UNIT}" "${MINDIR}/seance_gate"
ORDER=$( rcorder "${MINDIR}"/* 2>/dev/null | sed -e "s|^${MINDIR}/||" | tr '\n' ' ' )
t_like "${ORDER}" 'seance_gate.*cbsdd' \
    "with the BEFORE line, seance_gate is ordered ahead of a daemon that requires nothing"

grep -v '^# BEFORE:' "${UNIT}" > "${MINDIR}/seance_gate"
chmod 0755 "${MINDIR}/seance_gate"
ORDER=$( rcorder "${MINDIR}"/* 2>/dev/null | sed -e "s|^${MINDIR}/||" | tr '\n' ' ' )
t_unlike "${ORDER}" 'seance_gate.*cbsdd' \
    "and without it rcorder puts it AFTER the daemon: a gate that gates nothing"

t_done
