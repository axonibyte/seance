#!/bin/sh
# Tier 5 -- the conformance suite against the PSEUDO-CLUSTER adapter.
#
# The third adapter, and the reason this tier is called conformance rather than
# "the CBSD tests": tests/conformance/vectors.tsv is one oracle read by three
# implementations, and a contract only one of them keeps is not a contract.
# Tier 4 runs these vectors against the mock, t_conformance_real.sh runs them
# against CBSD, and this file runs them against the adapter that tiers 6 and 7
# drive the real verbs with.
#
# It runs here, in the guest, rather than in tier 6, because what the pseudo
# adapter needs is not a cluster -- it is ZFS. Its guests ARE datasets
# (adapter-pseudo.subr, pseudo_guest_create), so the suite needs a pool and
# root, and neither exists on the workstation. No jails, no bridge, no ssh: one
# dataset under the reset dataset, three guests in it, and the vectors.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

VECTORS="${T_ROOT}/tests/conformance/vectors.tsv"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the pseudo adapter's guests are ZFS datasets; this needs root"
    echo "t_conformance_pseudo: must run as root" >&2
    exit 2
fi

STATE=${REAPER_STATE:-/tank/state}

# The dataset the guests are children of. Named from the state dataset rather
# than resolved from the path afterwards, for the reason tests/shapeb's
# teardown gives: `zfs list <path>` answers with the CONTAINING dataset once
# nothing is mounted there (D-71), and this name is what gets destroyed.
STATE_DS=$( zfs list -H -o name "${STATE}" 2>/dev/null ) || STATE_DS=""
if [ -z "${STATE_DS}" ] ||
   [ "$( zfs get -H -o value mountpoint "${STATE_DS}" 2>/dev/null )" != "${STATE}" ]
then
    t_diag "${STATE} is not a dataset mountpoint; there is nothing to build on"
    echo "t_conformance_pseudo: no usable state dataset" >&2
    exit 2
fi

PSEUDO_DS="${STATE_DS}/conf-pseudo"
PSEUDO_AT="${STATE}/conf-pseudo"

# teardown -- armed before the first thing that can fail, so that a crash
# leaves nothing behind for `reaper reset` to refuse over.
#
# shellcheck disable=SC2329
#   Invoked by the harness's t_at_exit, not from this file's own text.
teardown()
{
    zfs destroy -r -f "${PSEUDO_DS}" > /dev/null 2>&1
    rm -rf "${PSEUDO_AT}" > /dev/null 2>&1
    return 0
}

zfs destroy -r -f "${PSEUDO_DS}" > /dev/null 2>&1
rm -rf "${PSEUDO_AT}" > /dev/null 2>&1
t_at_exit teardown

if ! zfs create -o "mountpoint=${PSEUDO_AT}" "${PSEUDO_DS}"; then
    t_diag "could not create ${PSEUDO_DS}"
    echo "t_conformance_pseudo: could not build the world" >&2
    exit 1
fi

# The world the vectors are written against, declared before the adapter is
# sourced: the pseudo adapter reads all three at source time.
SEANCE_PSEUDO_ROOT="${PSEUDO_DS}"
SEANCE_PSEUDO_MOUNT="${PSEUDO_AT}"
SEANCE_PSEUDO_DIR=$( t_tmpdir )/pseudo
export SEANCE_PSEUDO_ROOT SEANCE_PSEUDO_MOUNT SEANCE_PSEUDO_DIR

SEANCE_ADAPTER=${SEANCE_ADAPTER:-tests/cluster/adapter-pseudo.subr}

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/adapter-pseudo.subr
. "${T_ROOT}/${SEANCE_ADAPTER}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../conformance/run.subr
. "${T_ROOT}/tests/conformance/run.subr"

# The same three guests the mock's fixtures describe, so that the placeholders
# resolve to the same names in every run of this suite and a diff between two
# tiers' logs is a diff about behaviour.
SEANCE_CONF_JAIL=web01
SEANCE_CONF_VM=db01
SEANCE_CONF_HELD=arc01
SEANCE_CONF_ABSENT=nosuchguest
SEANCE_CONF_BADNAME=UPPER
export SEANCE_CONF_JAIL SEANCE_CONF_VM SEANCE_CONF_HELD \
    SEANCE_CONF_ABSENT SEANCE_CONF_BADNAME

count=$( conformance_count "${VECTORS}" )

# A vector file that shrank to nothing would otherwise pass in silence.
if [ "${count}" -lt 3 ]; then
    t_plan 1
    t_not_ok "tests/conformance/vectors.tsv holds vectors"
    t_diag "conformance_count said ${count}"
    t_done
fi

# The vectors, plus the five assertions that the world they assume was
# actually built -- a suite that ran against an empty node would agree with
# every "no such guest" row and prove nothing -- and the one layout claim the
# vectors deliberately do not carry (see the sysdir comment in vectors.tsv).
t_plan $(( count + 5 ))

adapter_init
t_rc 0 "adapter_init on the pseudo node" -- adapter_init

pseudo_guest_create "${SEANCE_CONF_JAIL}" jail alpha 1 > /dev/null 2>&1
pseudo_guest_create "${SEANCE_CONF_VM}" bhyve alpha 1 > /dev/null 2>&1
pseudo_guest_create "${SEANCE_CONF_HELD}" jail alpha 0 > /dev/null 2>&1
adapter_guest_hold "${SEANCE_CONF_HELD}" > /dev/null 2>&1

t_stdout_is "jail" "the world was built: ${SEANCE_CONF_JAIL} is a jail" \
    -- adapter_guest_type "${SEANCE_CONF_JAIL}"
t_stdout_is "bhyve" "the world was built: ${SEANCE_CONF_VM} is a VM" \
    -- adapter_guest_type "${SEANCE_CONF_VM}"
t_stdout_is "1" "the world was built: ${SEANCE_CONF_HELD} is held" \
    -- adapter_guest_held "${SEANCE_CONF_HELD}"

# THE LAYOUT CLAIM, which the shared vectors cannot make because it is
# different on every platform. Here the guest's configuration lives in a
# dataset CHILD of the guest's own root, which is what makes repl_sys_travels
# true for a pseudo guest and the configuration mirror empty of its own accord
# (D-84 item 3). A pseudo adapter that started answering with a path outside
# the guest's dataset would make tier 6 assert the mirror against a mechanism
# real nodes do not use, silently.
t_stdout_is "${PSEUDO_AT}/${SEANCE_CONF_JAIL}/sys" \
    "a pseudo guest's configuration directory is a child of its own dataset" \
    -- adapter_guest_sysdir "${SEANCE_CONF_JAIL}"

conformance_run "${VECTORS}"
t_done
