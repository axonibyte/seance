#!/bin/sh
# Tier 1 -- carp-repair: the demotion-recovery decision surface (D-192).
#
# lib/carp_repair.subr is the one place seance touches live CARP state. Every
# command that talks to the kernel goes through a seam (CARP_REPAIR_SYSCTL,
# CARP_REPAIR_IFCONFIG, CARP_REPAIR_KLDSTAT, CARP_REPAIR_SLEEP), so the whole
# decision surface is exercised here with no root, no carp and no interfaces:
# fake sysctl backed by a mutable counter file (a relative write adjusts it, as
# the kernel's does), fake ifconfig printing a bridge whose own vhid reads
# MASTER once the counter is 0 (a node reclaims its identity when it stops being
# demoted), and no-op sleep so nothing spends wall-clock.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
# shellcheck disable=SC2329
#   The fake_* functions below are invoked INDIRECTLY through the CARP_REPAIR_*
#   command seams (CARP_REPAIR_SYSCTL=fake_sysctl, and so on) -- which shellcheck
#   cannot see -- and driving the engine through them is the whole point.
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/carp_repair.subr
. "${T_ROOT}/lib/carp_repair.subr"

DIR=$( t_tmpdir )

# --- the seams, pointed at fixtures ----------------------------------------
CARP_REPAIR_SYSCTL=fake_sysctl
CARP_REPAIR_IFCONFIG=fake_ifconfig
CARP_REPAIR_KLDSTAT=fake_kldstat
CARP_REPAIR_SLEEP=true
CARP_REPAIR_SETTLE=0
CARP_REPAIR_BOOT_TIMEOUT=30
CARP_REPAIR_BOOT_STABLE=6

FAKE_LOADED=1
FAKE_ALLOW=1
FAKE_PREEMPT=1

fake_kldstat()
{
    [ "${FAKE_LOADED}" = "1" ] || return 1
    return 0
}

# A relative write, exactly like the kernel's: `demotion=<n>` adds n.
fake_sysctl()
{
    if [ "$1" = "-n" ]; then
        case "$2" in
            net.inet.carp.demotion)                 cat "${DIR}/demotion" ;;
            net.inet.carp.allow)                    printf '%s\n' "${FAKE_ALLOW}" ;;
            net.inet.carp.preempt)                  printf '%s\n' "${FAKE_PREEMPT}" ;;
            net.inet.carp.ifdown_demotion_factor)   printf '240\n' ;;
            net.inet.carp.senderr_demotion_factor)  printf '0\n' ;;
            *) return 1 ;;
        esac
        return 0
    fi
    case "$1" in
        net.inet.carp.demotion=*)
            _adj=${1#net.inet.carp.demotion=}
            _cur=$( cat "${DIR}/demotion" )
            printf '%s\n' "$(( _cur + _adj ))" > "${DIR}/demotion"
            ;;
    esac
}

# A single bridge0 carrying this node's own vhid (advskew 0). Its CARP state
# follows the counter: MASTER when demotion is 0, BACKUP while it is elevated --
# which is exactly why a stranded demotion keeps a node from its own identity.
# An interface named in ${DIR}/down prints without RUNNING (a true down link).
fake_ifconfig()
{
    if [ "$1" = "-l" ]; then cat "${DIR}/iflist"; return 0; fi
    grep -qxF "$1" "${DIR}/iflist" || return 1
    if grep -qxF "$1" "${DIR}/down" 2>/dev/null; then
        printf '%s: flags=8802<UP,BROADCAST,SIMPLEX,MULTICAST> metric 0 mtu 1500\n' "$1"
    else
        printf '%s: flags=8843<UP,BROADCAST,RUNNING,SIMPLEX,MULTICAST> metric 0 mtu 1500\n' "$1"
    fi
    if [ "$1" = "bridge0" ]; then
        printf '\tinet 192.0.2.76 netmask 0xffffffff broadcast 192.0.2.76 vhid 242\n'
        if [ "$( cat "${DIR}/demotion" )" = "0" ]; then _st=MASTER; else _st=BACKUP; fi
        printf '\tcarp: %s vhid 242 advbase 1 advskew 0\n' "${_st}"
    fi
}

# reset <demotion>  -- a healthy single-bridge node with the given counter.
reset()
{
    printf 'bridge0\n' > "${DIR}/iflist"
    : > "${DIR}/down"
    printf '%s\n' "$1" > "${DIR}/demotion"
    FAKE_LOADED=1; FAKE_ALLOW=1; FAKE_PREEMPT=1
}

t_plan 17

# --- preconditions ----------------------------------------------------------
reset 720; FAKE_LOADED=0
t_rc 2 "carp not loaded is a contract error, not a stale counter" -- carp_repair_check

reset 720; FAKE_PREEMPT=0
t_rc 2 "preempt=0 is refused: a repair on a node that cannot reclaim changes nothing" -- \
    carp_repair_check

# --- check: the three verdicts ---------------------------------------------
reset 0
t_rc 0 "demotion 0 with own vhid MASTER is healthy" -- carp_repair_check
t_like "$( reset 0; carp_repair_check )" 'nothing to repair' \
    "and it says nothing needs repairing"

reset 720
t_rc 1 "a positive demotion with every vhid interface active is stale (repairable)" -- \
    carp_repair_check
t_like "$( reset 720; carp_repair_check )" 'repairable' "and it says so"

reset 720; printf 'bridge0\n' > "${DIR}/down"
t_rc 2 "a demotion with a DOWN vhid interface is TRUE -- refused, not cleared" -- \
    carp_repair_check
t_like "$( reset 720; printf 'bridge0\n' > "${DIR}/down"; carp_repair_check )" 'REFUSING' \
    "and it says it is refusing"

# --- fix: convergence, both signs, and the no-op ---------------------------
reset 720
out=$( carp_repair_fix ); rc=$?
t_is "${rc}" "0" "fix converges a stale 720 and returns repaired"
t_is "$( cat "${DIR}/demotion" )" "0" "the counter is 0 after the fix"
t_like "${out}" 'REPAIRED' "and the node is MASTER for its own identity again"

reset -240
carp_repair_fix > /dev/null
t_is "$( cat "${DIR}/demotion" )" "0" "a NEGATIVE counter is converged to 0 too (the same lie, other sign)"

reset 0
out=$( carp_repair_fix ); rc=$?
t_is "${rc}" "0" "fix on a healthy node is a no-op that returns ok"
t_is "$( cat "${DIR}/demotion" )" "0" "and writes nothing"

# --- a true-demotion node is refused by fix as well, not just check --------
reset 720; printf 'bridge0\n' > "${DIR}/down"
t_rc 2 "fix refuses a TRUE demotion, leaving the counter untouched" -- carp_repair_fix
t_is "$( cat "${DIR}/demotion" )" "720" "the counter is left exactly as it was"

# --- boot mode: wait for settle, then converge -----------------------------
reset 720
t_rc 0 "carp-repair --boot settles then converges a stranded boot demotion" -- \
    carp_repair_run boot

t_done
