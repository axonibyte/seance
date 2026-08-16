#!/bin/sh
# Tier 5 -- the configuration mirror, end to end, on a real CBSD jail.
#
# D-82 says a jail's configuration does not travel with its data and that
# seance therefore carries it itself, in one dataset per node. D-84 records
# what shape A can and cannot prove about that: tier 6 asserts the MECHANISM
# (the mirror is created in the right pool, snapshotted with the tick's name,
# replicated, hidden on arrival) against a pseudo-cluster whose guests all
# carry their configuration inside their own datasets anyway, so the mirror
# there is empty of its own accord and seeded by hand. The sentence tier 6
# cannot say is written down in tests/tier5/README:
#
#     "That a real JAIL registers out of it is tier 5's."
#
# This file is that sentence. It runs one real `seance repl` tick on a real
# CBSD node, then plays the successor's half of a promotion against what the
# tick produced, and finishes by starting the jail from a configuration
# directory that came out of the mirror and nowhere else.
#
# WHAT IS AND IS NOT SIMULATED, stated because the difference is the whole
# value of the file. Real: the CBSD node, the jail, the mirror dataset, the
# rsync-free copy into it, the recursive snapshot, the zfs send and receive of
# that snapshot into a standby tree, promote_sys_restore's read-only mount and
# copy, and `cbsd jregister rcfile=` followed by `cbsd jstart`. Simulated: the
# PEER. There is one node in this session, so the heir named in the
# configuration is unreachable and the tick's sends to it fail -- which is
# fine and is asserted rather than hidden, because the mirror is made BEFORE
# any peer is contacted and its snapshot is taken whether the peer answers or
# not. The replica the successor restores from is received from that snapshot
# on this pool, which is byte-for-byte what a peer would have received.
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

if [ "$( id -u )" -ne 0 ]; then
    t_diag "shape B builds a real CBSD node; it needs root"
    echo "t_promote_real: must run as root" >&2
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

J=${SHAPEB_JAIL}
WD=$( shapeb_workdir )
POOL=$( zfs list -H -o name "${WD}/jails-data" )
SYSDIR="${WD}/jails-system/${J}"
RCFILE="${SYSDIR}/rc.conf_${J}"

WORK=$( t_tmpdir )
SEANCE_CONF="${WORK}/seance.conf"
SEANCE_STATE_DIR="${WD}/var/db/seance"
SEANCE_RUN_DIR="${WORK}/run"
export SEANCE_CONF SEANCE_STATE_DIR SEANCE_RUN_DIR

mkdir -p "${SEANCE_STATE_DIR}" "${SEANCE_RUN_DIR}"

# The fleet, one real node and one fiction. bravo's mgmt address is in
# 192.0.2.0/24 -- RFC 5737 TEST-NET-1, which exists precisely so that a
# document or a test can name an address nothing will answer on. The tick's
# send to it MUST fail; what this file is about is everything the tick does
# before it gets there.
cat > "${SEANCE_CONF}" <<EOF
cadence=60
retention_recent=14400
retention_hourly=172800
skew_tolerance=120
ssh_user=root
ssh_port=22
ssh_extra_opts=-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 -o BatchMode=yes -o LogLevel=ERROR
standby_root=${POOL}/standby

node_${SHAPEB_NODE}_nodename=${SHAPEB_NODE}
node_${SHAPEB_NODE}_mgmt=127.0.0.1
node_${SHAPEB_NODE}_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=192.0.2.11
EOF

SEANCE="${T_ROOT}/bin/seance"

t_plan 31

# ---------------------------------------------------------------------------
# One tick
# ---------------------------------------------------------------------------

tick=$( t_tmpdir )
sh "${SEANCE}" repl --now > "${tick}/out" 2> "${tick}/err" < /dev/null
tick_rc=$?

# The tick FAILED, and that is the expected verdict: its one peer is
# unreachable. Asserted rather than ignored -- a tick that exited 0 here would
# mean something answered on TEST-NET-1, and every assertion after this one
# would be about a fleet nobody described.
t_is "${tick_rc}" "1" "the tick fails: its only heir is unreachable (TEST-NET-1)"
t_like "$( cat "${tick}/out" "${tick}/err" )" 'bravo' \
    "and it says which peer it could not reach"

SYS_DS="${POOL}/seance-sys"
SYS_MP="${SEANCE_STATE_DIR}/sys"

# --- the mirror dataset ------------------------------------------------------

t_is "$( zfs list -H -o name "${SYS_DS}" 2>/dev/null )" "${SYS_DS}" \
    "repl created <pool-of-jails-data>/seance-sys (D-82)"
t_is "$( zfs get -H -o value mountpoint "${SYS_DS}" )" "${SYS_MP}" \
    "mounted inside the state directory (D-3)"
t_is "$( mount -p | awk -v p="${SYS_MP}" '$2 == p { print $1 }' )" "${SYS_DS}" \
    "and it really is mounted there"

# --- what is in it -----------------------------------------------------------

if [ -f "${SYS_MP}/${J}/rc.conf_${J}" ]; then
    t_ok "the mirror carries ${J}/rc.conf_${J}"
else
    t_not_ok "the mirror carries ${J}/rc.conf_${J}"
    find "${SYS_MP}" -maxdepth 2 2>&1 | sed -e 's/^/# /'
fi

t_is "$( sha256 -q "${SYS_MP}/${J}/rc.conf_${J}" 2>/dev/null )" \
    "$( sha256 -q "${RCFILE}" )" \
    "and it is byte-identical to the one in \${jailsysdir}"

# The VM's configuration is NOT in the mirror: ${jailsysdir}/<vm> is a symlink
# into the VM's own dataset (sudoexec/bcreate:599), so it already travels and
# repl_sys_travels says so. This is D-84 item 3 measured on the platform whose
# asymmetry it exists for -- and the first time both halves of that asymmetry
# have been real at once.
if [ -e "${SYS_MP}/${SHAPEB_VM}" ]; then
    t_not_ok "a VM's configuration is not mirrored: it already travels"
    t_diag "unexpectedly present: ${SYS_MP}/${SHAPEB_VM}"
else
    t_ok "a VM's configuration is not mirrored: it already travels"
fi

# The held guest is skipped by the tick (D-94), so its configuration is not in
# the mirror either. Stated so that a future change to that rule is noticed
# here rather than found by a survivor.
if [ -e "${SYS_MP}/${SHAPEB_HELD}" ]; then
    t_not_ok "a guest held here is not replicated, so it is not mirrored (D-94)"
else
    t_ok "a guest held here is not replicated, so it is not mirrored (D-94)"
fi

# --- the snapshot ------------------------------------------------------------
#
# The mirror's lineage is the fleet's lineage: the same @seance-<home>-<ts>
# grammar every other dataset carries, so retention, staleness and the ladder
# read it with the parser they already have.

SNAP=$( zfs list -H -o name -t snapshot -r "${SYS_DS}" | head -1 )
t_like "${SNAP}" "^${SYS_DS}@seance-${SHAPEB_NODE}-[0-9]{8}T[0-9]{6}Z$" \
    "the mirror is snapshotted with the tick's own name grammar"

GUEST_SNAP=$( zfs list -H -o name -t snapshot -r "${POOL}/${J}" | head -1 )
t_is "${GUEST_SNAP##*@}" "${SNAP##*@}" \
    "with the same instant as the guest's own snapshot: one tick, one moment"

# ---------------------------------------------------------------------------
# The successor's half
#
# A peer would have received that snapshot into <standby_root>/<home>/seance-sys.
# There is no peer, so the same send is received here, into exactly that path.
# From promote_sys_restore's point of view the two are indistinguishable: it is
# handed a dataset name and a destination.
# ---------------------------------------------------------------------------

REPLICA="${POOL}/standby/${SHAPEB_NODE}/seance-sys"

zfs create -o canmount=off -o mountpoint=none "${POOL}/standby" 2>/dev/null
zfs create -o canmount=off -o mountpoint=none "${POOL}/standby/${SHAPEB_NODE}" \
    2>/dev/null

# THE ENGINE'S OWN RECEIVE, flag for flag: `zfs recv -s -u -x mountpoint
# -x canmount` is the contract written at the top of lib/repl.subr, and
# repl_remote_enforce_law then sets canmount=noauto on every dataset that
# arrived (D-65). Both halves are reproduced here rather than approximated:
# a receive without them leaves canmount=on, and the first `zfs set mountpoint`
# afterwards mounts the replica READ-WRITE before anybody asked -- which is the
# shadow-mount law being broken, and it is exactly what happened the first time
# this file ran with a hand-rolled `zfs recv -u -x mountpoint`.
send_rc=$( t_tmpdir )/send.rc
( zfs send "${SNAP}"; echo $? > "${send_rc}" ) |
    zfs recv -s -u -x mountpoint -x canmount "${REPLICA}"
recv_rc=$?
t_is "$( cat "${send_rc}" )-${recv_rc}" "0-0" \
    "the mirror's snapshot is received into <standby_root>/<home>/seance-sys"

zfs set canmount=noauto "${REPLICA}" || t_diag "could not enforce canmount"

# The shadow-mount law, both properties, on the replica promote_sys_restore is
# about to be handed.
t_is "$( zfs get -H -o value,source mountpoint "${REPLICA}" | awk '{ print $2 }' )" \
    "inherited" "and the replica inherits its mountpoint rather than owning one"
t_is "$( zfs get -H -o value canmount "${REPLICA}" )" "noauto" \
    "and cannot mount by accident (D-65)"

# ---------------------------------------------------------------------------
# Take the jail's configuration away
#
# Not "pretend it is gone": unregister it and MOVE THE DIRECTORY ASIDE, so that
# nothing at ${jailsysdir}/<n> can contribute to what happens next. If the
# mirror is not sufficient, everything below fails.
# ---------------------------------------------------------------------------

t_rc 0 "the jail is unregistered" -- shapeb_cbsd junregister jname="${J}"
mv "${SYSDIR}" "${SYSDIR}.aside" || t_diag "could not move the sysdir aside"

if [ -e "${SYSDIR}" ]; then
    t_not_ok "and its configuration directory is gone"
else
    t_ok "and its configuration directory is gone"
fi

# ---------------------------------------------------------------------------
# promote_sys_restore, called the way lib/promote.subr calls it
# ---------------------------------------------------------------------------

# The library, sourced as the dispatcher sources it. promote_sys_restore uses
# zfs.subr's helpers and promote's own undo/note printers, and nothing else.
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
# shellcheck source=../../lib/verify.subr
. "${T_ROOT}/lib/verify.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/gate.subr
. "${T_ROOT}/lib/gate.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/promote.subr
. "${T_ROOT}/lib/promote.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/adapter.subr
. "${T_ROOT}/${SEANCE_ADAPTER:-lib/adapter.subr}"

SCRATCH=$( t_tmpdir )/promote

restore=$( t_tmpdir )
promote_sys_restore "${J}" "${REPLICA}" "${SYSDIR}" "${SCRATCH}" \
    > "${restore}/out" 2> "${restore}/err"
restore_rc=$?

t_is "${restore_rc}" "0" "promote_sys_restore puts the configuration back"
t_like "$( cat "${restore}/out" )" "restored ${J}'s configuration" \
    "and says so, naming the dataset it came out of"

if [ -f "${RCFILE}" ]; then
    t_ok "rc.conf_${J} is back at \${jailsysdir}/${J}/"
else
    t_not_ok "rc.conf_${J} is back at \${jailsysdir}/${J}/"
    find "${SYSDIR}" -maxdepth 1 2>&1 | sed -e 's/^/# /'
fi

t_is "$( sha256 -q "${RCFILE}" )" "$( sha256 -q "${SYSDIR}.aside/rc.conf_${J}" )" \
    "and it is byte-identical to the one that was taken away"

# The read-only mount is not left behind, and the replica's mountpoint is put
# back to what it was: `zfs mount -o ro` is a property of the mount, so there
# is nothing to undo but the mountpoint itself.
t_is "$( mount -p | awk -v p="${SCRATCH}/sysmirror" '$2 == p { print $1 }' )" "" \
    "the scratch read-only mount is gone afterwards"
t_is "$( zfs get -H -o value,source mountpoint "${REPLICA}" | awk '{ print $2 }' )" \
    "inherited" "and the replica's mountpoint is inherited again"

# ---------------------------------------------------------------------------
# The claim itself: the jail registers and starts out of the mirror's copy
# ---------------------------------------------------------------------------

t_rc 0 "cbsd jregister accepts the restored rcfile" \
    -- adapter_guest_register "${J}" "${RCFILE}"
t_stdout_is "jail" "and the guest is a jail on this node again" \
    -- adapter_guest_type "${J}"
t_rc 0 "and it STARTS" -- adapter_guest_start "${J}"
t_stdout_is "1" "and it is running" -- adapter_guest_running "${J}"
t_rc 0 "and stops again" -- adapter_guest_stop "${J}"

rm -rf "${SYSDIR}.aside"
zfs destroy -r "${POOL}/standby" 2>/dev/null

# ---------------------------------------------------------------------------
# The guest is left as it was found
# ---------------------------------------------------------------------------

shapeb_down_and_check

t_done
