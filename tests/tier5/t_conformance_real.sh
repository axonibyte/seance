#!/bin/sh
# Tier 5 -- the conformance suite against REAL CBSD (TESTING.md §6).
#
# The same tests/conformance/vectors.tsv tier 4 runs against the mock and
# t_conformance_pseudo.sh runs against the pseudo-cluster adapter, run here
# against lib/adapter.subr and a genuine CBSD 15.0.9 node with three guests on
# it. Everything the vectors assert is a shape -- fields, exit codes, what
# empty stdout is allowed to mean -- and this is where those shapes stop being
# a description of CBSD and become CBSD.
#
# It also carries the claims the vectors cannot carry, because they are about
# this platform rather than about the contract: where CBSD puts a guest's
# datasets, where it puts its configuration, and that the two answers the
# adapter gives about the same guest agree with `zfs list` and with `mount`.
# Those are the M0 notes' "read from source, UNVERIFIED live" items
# (docs/cbsd-module-notes.md §6, §10), and this file is where they were run.
#
# The LIFECYCLE -- start, hold, refuse, release, stop, unregister, register --
# is t_lifecycle_real.sh: the vectors are read-only by construction and running
# them against a node whose guests are being started underneath them would make
# a passing suite a matter of timing.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../shapeb/lib/shapeb.subr
. "${T_ROOT}/tests/shapeb/lib/shapeb.subr"

VECTORS="${T_ROOT}/tests/conformance/vectors.tsv"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "shape B builds a real CBSD node; it needs root"
    echo "t_conformance_real: must run as root" >&2
    exit 2
fi

shapeb_up
up_rc=$?
if [ "${up_rc}" -ne 0 ]; then
    t_plan 1
    t_not_ok "the shape-B substrate came up"
    t_diag "shapeb_up exited ${up_rc}"
    t_done
fi

SEANCE_ADAPTER=${SEANCE_ADAPTER:-lib/adapter.subr}

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/adapter.subr
. "${T_ROOT}/${SEANCE_ADAPTER}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../conformance/run.subr
. "${T_ROOT}/tests/conformance/run.subr"

SEANCE_CONF_JAIL=${SHAPEB_JAIL}
SEANCE_CONF_VM=${SHAPEB_VM}
SEANCE_CONF_HELD=${SHAPEB_HELD}
SEANCE_CONF_ABSENT=nosuchguest
SEANCE_CONF_BADNAME=UPPER
export SEANCE_CONF_JAIL SEANCE_CONF_VM SEANCE_CONF_HELD \
    SEANCE_CONF_ABSENT SEANCE_CONF_BADNAME

WD=$( shapeb_workdir )

count=$( conformance_count "${VECTORS}" )

if [ "${count}" -lt 3 ]; then
    t_plan 1
    t_not_ok "tests/conformance/vectors.tsv holds vectors"
    t_diag "conformance_count said ${count}"
    t_done
fi

t_plan $(( count + 16 ))

# ---------------------------------------------------------------------------
# The contract, against CBSD
# ---------------------------------------------------------------------------

conformance_run "${VECTORS}"

# ---------------------------------------------------------------------------
# The node's own facts, against the files CBSD wrote them into
#
# The vectors can only say "an absolute path"; these say WHICH path, and they
# read the answer out of CBSD's own workdir rather than out of the adapter that
# is being tested.
# ---------------------------------------------------------------------------

t_stdout_is "$( cat "${WD}/nodename" )" \
    "adapter_node_self is the name in \${workdir}/nodename (cbsd.conf:52)" \
    -- adapter_node_self

t_stdout_is "${WD}" \
    "adapter_fact workdir is \$cbsd_workdir from rc.conf (cbsd.conf:28-36)" \
    -- adapter_fact workdir

t_stdout_is "${WD}/jails-system" \
    "adapter_fact jailsysdir is \${workdir}/jails-system (cbsd.conf:71)" \
    -- adapter_fact jailsysdir

t_stdout_is "${WD}/jails-data" \
    "adapter_fact jaildatadir is \${workdir}/jails-data (cbsd.conf:65)" \
    -- adapter_fact jaildatadir

t_stdout_is "$( freebsd-version -k )" \
    "adapter_kernel_version is freebsd-version -k, exactly" \
    -- adapter_kernel_version

# ---------------------------------------------------------------------------
# A guest's configuration directory
#
# ${jailsysdir}/<name>/rc.conf_<name> is the file `cbsd jregister rcfile=`
# takes, so a survivor that has a guest's data and not this directory cannot
# start it -- which is the whole of D-82. That it exists here, with that name,
# is the M0 note's "UNVERIFIED live" turned over.
# ---------------------------------------------------------------------------

t_stdout_is "${WD}/jails-system/${SHAPEB_JAIL}" \
    "a jail's sysdir is \${jailsysdir}/<name> (sudoexec/jcreate:710-729)" \
    -- adapter_guest_sysdir "${SHAPEB_JAIL}"

if [ -f "${WD}/jails-system/${SHAPEB_JAIL}/rc.conf_${SHAPEB_JAIL}" ]; then
    t_ok "and jcreate left rc.conf_<name> in it"
else
    t_not_ok "and jcreate left rc.conf_<name> in it"
    find "${WD}/jails-system/${SHAPEB_JAIL}" -maxdepth 1 2>&1 |
        sed -e 's/^/# /'
fi

# The jail's is NOT inside its own dataset and the VM's IS -- the asymmetry
# D-77 opened and D-82 answers. Measured rather than asserted from the type:
# realpath of the sysdir against the guest's own mountpoint.
t_is "$( realpath "$( adapter_guest_sysdir "${SHAPEB_JAIL}" )" )" \
    "${WD}/jails-system/${SHAPEB_JAIL}" \
    "a JAIL's sysdir is a plain directory on the workdir dataset"

t_is "$( realpath "$( adapter_guest_sysdir "${SHAPEB_VM}" )" )" \
    "$( adapter_guest_mountpoint "${SHAPEB_VM}" bhyve )" \
    "a VM's sysdir is a symlink into its own dataset (sudoexec/bcreate:599)"

# ---------------------------------------------------------------------------
# Datasets: what CBSD created, named by the adapter
#
# M0 read this out of sudoexec/mkdatadir and sudoexec/bcreate and marked it
# UNVERIFIED because it had no guest. These four assertions are that guest.
# ---------------------------------------------------------------------------

POOL=$( zfs list -H -o name "${WD}/jails-data" )

t_stdout_is "${POOL}/${SHAPEB_JAIL}" \
    "a jail's dataset is <pool-of-jails-data>/<name> (sudoexec/mkdatadir:20-21)" \
    -- adapter_guest_datasets "${SHAPEB_JAIL}"

t_is "$( zfs get -H -o value mountpoint "${POOL}/${SHAPEB_JAIL}" )" \
    "${WD}/jails-data/${SHAPEB_JAIL}-data" \
    "and CBSD mounted it at \${jaildatadir}/<name>-data"

t_stdout_is "${POOL}/${SHAPEB_VM}
${POOL}/${SHAPEB_VM}/dsk1.vhd" \
    "a VM's datasets are its root and its zvols (sudoexec/bcreate:573-600)" \
    -- adapter_guest_datasets "${SHAPEB_VM}"

t_is "$( zfs get -H -o value mountpoint "${POOL}/${SHAPEB_VM}" )" \
    "${WD}/vm/${SHAPEB_VM}" \
    "and CBSD mounted it at \${workdir}/vm/<name> (sudoexec/bcreate:579)"

# The links a replicated VM needs, against the ones CBSD made itself.
t_is "$( readlink "${WD}/jails-data/${SHAPEB_VM}-data" )" \
    "${WD}/vm/${SHAPEB_VM}" \
    "adapter_guest_links names a link CBSD really makes (sudoexec/bcreate:598)"

# ---------------------------------------------------------------------------
# Liveness, on a guest that exists and is not running
#
# `cbsd jstatus jname=<n> invert=1` for a guest that EXISTS was source-only in
# M0's notes (§6) and is named in tests/tier5/README as a required assertion.
# The running half belongs to t_lifecycle_real.sh, which starts one.
# ---------------------------------------------------------------------------

t_stdout_is "0" \
    "a guest that exists and is stopped reports jid 0, not absent" \
    -- adapter_guest_running "${SHAPEB_JAIL}"

t_stdout_is "1" "the held guest is held (cbsd jswmode mode=slave, D-21)" \
    -- adapter_guest_held "${SHAPEB_HELD}"

t_done
