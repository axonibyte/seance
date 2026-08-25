#!/bin/sh
# Tier 5 -- where a replica is mounted, against real CBSD (D-178, D-181).
#
# THE FLEET'S SHAPE, BUILT WITH CBSD'S OWN VERBS. The first real fleet this
# module met is three clustered nodes on which every guest is a bhyve VM whose
# data lives on the JAIL-shaped path -- `data=${jaildatadir}/<name>-data`, a
# dataset mounted exactly there, no zvols (the disks are files inside the data
# directory), and ${jailsysdir}/<name> a plain directory rather than the
# symlink `cbsd bcreate` makes on the path this substrate's VM was created by
# (sudoexec/bcreate:549-566 is the branch that produces it: with an external
# mounter, CBSD makes the sysdir with mkdir and links nothing).
#
# Promotion on that fleet used to ask the adapter where a guest of the
# replica's type belongs HERE and mount the replica there. This file is the
# other answer: the path is read out of the guest's own configuration, which
# seance already replicates, before anything is mounted.
#
# ONE DIRECTORY DEEPER THAN THE FLEET, DELIBERATELY. The fleet's own data path
# is ${jaildatadir}/<name>-data, which is exactly what this platform's
# convention for a JAIL would derive -- and a replica whose tree carries no
# zvols is a tree that looks like a jail. A test at the fleet's literal path
# therefore could not tell a path that was READ from one that was DERIVED and
# happened to agree. The guest below lives at ${jaildatadir}/vmdata/<name>-data,
# which no convention this platform has produces, so the assertions mean what
# they say.
#
# WHAT IS NOT ASSERTED HERE, and where it is: the guest is not STARTED. A bhyve
# VM in this substrate has never been booted (tests/tier5/README's own
# "STILL UNVERIFIED" list, and shapeb.subr's VM is created for its layout
# only) -- there is no guest OS in it and the reaper guest is not a
# virtualisation host. That a guest promoted to a path its own configuration
# named starts and reports running is tier 6's, where the pseudo-cluster's
# vmj01 is built in this same shape and is started, run and failed back.
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
    echo "t_mountpath_real: must run as root" >&2
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

V=${SHAPEB_VM}
WD=$( shapeb_workdir )
POOL=$( zfs list -H -o name "${WD}/jails-data" )

# Where this guest is being moved to: inside the jails-data area, one directory
# deeper than any convention this platform has.
VMDATA="${WD}/jails-data/vmdata/${V}-data"
VMDS="${POOL}/${V}-data"

WORK=$( t_tmpdir )
SEANCE_CONF="${WORK}/seance.conf"
SEANCE_STATE_DIR="${WD}/var/db/seance"
SEANCE_RUN_DIR="${WORK}/run"
export SEANCE_CONF SEANCE_STATE_DIR SEANCE_RUN_DIR
mkdir -p "${SEANCE_STATE_DIR}" "${SEANCE_RUN_DIR}"

# One real node and one fiction, whose mgmt address is in RFC 5737 TEST-NET-1
# so that nothing can answer on it. The tick's send MUST fail; what this file
# is about is everything the tick does before it gets there.
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

t_plan 60

# ---------------------------------------------------------------------------
# Move the VM onto the fleet's layout, with CBSD's own verbs
#
# `cbsd junregister` dumps the guest's registration into
# ${jailrcconfdir}/rc.conf_<n> with the workdir replaced by the CBSDROOT token
# (sudoexec/junregister:140-141); `cbsd jregister rcfile=` puts this node's
# workdir back and registers what the file says (sudoexec/jregister:151,215).
# Editing the data path between the two is how an administrator moves a guest,
# and it is the only way seance's own code is ever told about it.
# ---------------------------------------------------------------------------

DUMP="${WD}/jails-rcconf/rc.conf_${V}"

t_rc 0 "the VM unregisters, dumping its own registration" \
    -- shapeb_cbsd junregister jname="${V}" inter=0

if [ -r "${DUMP}" ]; then
    t_ok "and the dump is at \${jailrcconfdir}/rc.conf_<name>"
else
    t_not_ok "and the dump is at \${jailrcconfdir}/rc.conf_<name>"
    find "${WD}/jails-rcconf" -maxdepth 1 2>&1 | sed -e 's/^/# /'
fi


# WHAT THE DUMP ACTUALLY CARRIES, observed rather than assumed -- and it is not
# what junregister's own source says it should be. `sudoexec/junregister:140-141`
# runs `replacewdir file0=<dump> old=${workdir} new="CBSDROOT"` after
# `jmkrcconf`, which is documented (and used by `jregister`, below) as the way
# CBSD moves a registration between nodes whose workdirs differ. On CBSD 15.0.9
# in this substrate the dump comes back with the workdir NOT tokenised:
# `data="<workdir>/vm/<name>"`, absolute. The cause is unverified -- the sed in
# `tools/replacewdir:22` runs behind a `[ -r "${file}" ]` test and inside a
# loop bounded by `$#`, and this file is not the place to work out which of
# those did it.
#
# The row asserts the OBSERVATION, which makes it the tripwire this tier exists
# to be: if a later CBSD tokenises here, this is where it is noticed, and
# seance reads both forms either way (the CBSDROOT rows in
# tests/tier4/t_adapter_parse.sh, and the expansion asserted below).
t_diag "the dump's data line: $( grep '^data=' "${DUMP}" 2>/dev/null )"
t_like "$( cat "${DUMP}" 2>/dev/null )" "^data=\"${WD}/vm/${V}\";" \
    "carrying the data path CBSD created it with, absolute -- junregister did NOT tokenise the workdir here"

# The two symlinks bcreate made to the old data directory, and the zvol. The
# fleet has neither: its VMs' disks are files inside the data directory, which
# is why a replica of one carries no volumes at all.
rm -f "${WD}/jails-data/${V}-data" "${WD}/jails-system/${V}"

t_rc 0 "the zvol goes: on the fleet a VM's disks are files, so a replica carries no volumes" \
    -- zfs destroy "${POOL}/${V}/dsk1.vhd"

# The parent directory FIRST. `zfs set mountpoint=` remounts a mounted dataset
# at the new path and creates only the leaf directory; with the parent missing
# it leaves the dataset unmounted and says so on stderr. The first run of this
# file swallowed that with a `2>/dev/null` on the mount that followed, and died
# three lines later creating a file in a directory nothing was mounted at --
# which is the false-pass this repository keeps finding, written by hand.
mkdir -p "$( dirname "${VMDATA}" )" || t_diag "creating ${VMDATA}'s parent failed"

t_rc 0 "the dataset is renamed so its NAME carries -data, as the fleet's do" \
    -- zfs rename "${POOL}/${V}" "${VMDS}"
t_rc 0 "and moved onto the jail-shaped path" \
    -- zfs set "mountpoint=${VMDATA}" "${VMDS}"

zfs mount "${VMDS}" > /dev/null 2>&1

t_is "$( zfs get -H -o value mounted "${VMDS}" )" "yes" \
    "and it really is mounted there -- asked, not assumed"
t_is "$( mount -p | awk -v p="${VMDATA}" '$2 == p { print $1 }' )" "${VMDS}" \
    "at the path the rest of this file is about"

# The disk. CBSD gave this VM a zvol and a SYMLINK to its /dev/zvol path inside
# the data directory (sudoexec/bcreate:573-600, restored after a receive by
# sudoexec/zfs-recv:82-93). The zvol is gone now, so that symlink dangles --
# and `touch` through a dangling symlink is ENOENT, which is how the first two
# runs of this file died with a mounted dataset and a file it could not create.
# The fleet's VMs have a plain FILE there, so the link goes and a file replaces
# it.
rm -f "${VMDATA}/dsk1.vhd"
t_rc 0 "the VM's disk is a file inside its data directory, the way the fleet's are" \
    -- touch "${VMDATA}/dsk1.vhd"

# ${jailsysdir}/<name> is a plain directory on this layout, not a symlink into
# the guest's dataset -- which is what makes its configuration NOT travel with
# its data, and the configuration mirror the only thing that carries it.
#
# ITS CONTENTS COME WITH IT, and an empty directory here is not this layout but
# a broken guest. On the symlink layout the guest's system files -- local.sqlite
# above all -- live inside the data directory, because that is where the
# symlink pointed. `cbsd bls` SKIPS a VM whose ${jailsysdir}/<n>/local.sqlite it
# cannot read (bhyvectl/bls:393-399) unless mnt_start is set, so an empty sysdir
# makes the guest vanish from every listing while remaining registered --
# observed, on the second run of this file, as "no such guest on this node".
mkdir -p "${WD}/jails-system/${V}" || t_diag "creating the sysdir failed"
cp -a "${VMDATA}/." "${WD}/jails-system/${V}/" || t_diag "copying the system files failed"
rm -f "${WD}/jails-system/${V}/dsk1.vhd"

# And the configuration leaves the DATA directory, which is the other half of
# this layout: on the fleet a VM's rc.conf is in its sysdir and its disks are in
# its data, and the two are different directories. Leaving a stale copy in the
# data would also give the promotion ceremony a second, older answer to read
# (promote_config_read looks in the replica before the mirror, deliberately).
rm -f "${VMDATA}/rc.conf_${V}"

# THE ABSOLUTE PATH, not the CBSDROOT token, and the reason is the row above:
# this platform's own tokenisation did not happen, so whether the reverse
# substitution happens on `jregister` is not a thing this file may lean on. An
# administrator moving a guest between two nodes with the same workdir writes
# the path. What seance does with a token is asserted below, against the
# adapter, where it is seance's own behaviour and not CBSD's.
sed -i '' -e "s|^data=.*|data=\"${VMDATA}\";|" "${DUMP}" ||
    t_diag "editing the dumped registration failed"

t_rc 0 "and it registers again from the edited registration" \
    -- shapeb_cbsd jregister jname="${V}" rcfile="${DUMP}"

# ---------------------------------------------------------------------------
# What the platform, and the guest's own configuration, now say
# ---------------------------------------------------------------------------

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

SEANCE_TMP_REGISTRY="${WORK}/registry"
: > "${SEANCE_TMP_REGISTRY}"
export SEANCE_TMP_REGISTRY

RCFILE="${WD}/jails-system/${V}/rc.conf_${V}"

if [ -r "${RCFILE}" ]; then
    t_ok "jregister moved the registration into \${jailsysdir}/<name>/ (jregister:215)"
else
    t_not_ok "jregister moved the registration into \${jailsysdir}/<name>/ (jregister:215)"
    find "${WD}/jails-system/${V}" -maxdepth 1 2>&1 | sed -e 's/^/# /'
fi

t_like "$( cat "${RCFILE}" 2>/dev/null )" "^data=\"${VMDATA}\"" \
    "carrying the data path it was registered with, which is what seance must mount at"

# The token, against the real adapter and this node's real workdir. seance
# resolves CBSDROOT the way `jregister` is documented to (sudoexec/jregister:151,
# tools/replacewdir:22) because a registration that carries one names a path
# relative to whichever node reads it -- and a ceremony that mounted the
# literal would mount somewhere the registration is not about.
printf 'data="CBSDROOT/jails-data/vmdata/%s-data";\n' "${V}" > "${WORK}/rc.conf_token"
t_stdout_is "${VMDATA}" \
    "and a registration carrying CBSDROOT resolves to THIS node's workdir" \
    -- adapter_config_data_path "${WORK}/rc.conf_token"

t_stdout_is "${VMDATA}" \
    "and adapter_config_data_path reads that file's data path, whatever quoting CBSD used" \
    -- adapter_config_data_path "${RCFILE}"

t_stdout_is "${VMDATA}" \
    "the PLATFORM records the same path for it (display=jname,data)" \
    -- adapter_guest_data_path "${V}"

t_stdout_is "bhyve" "and still calls it a bhyve guest" -- adapter_guest_type "${V}"

t_stdout_is "${VMDS}" \
    "its dataset resolves through that path -- one dataset, no volumes, like the fleet's" \
    -- adapter_guest_datasets "${V}"

# The asymmetry D-82 turns on, measured on this layout rather than assumed from
# the type: this VM's configuration directory is NOT inside its own dataset, so
# it does not travel with the data and `repl` has to mirror it.
t_is "$( realpath "$( adapter_guest_sysdir "${V}" )" )" "${WD}/jails-system/${V}" \
    "its sysdir is a plain directory on the workdir dataset, not a symlink into its data"
t_rc 1 "so repl_sys_travels says its configuration does NOT travel with its datasets" \
    -- repl_sys_travels "${V}"

# ---------------------------------------------------------------------------
# One tick: the mirror has to carry this VM's configuration
# ---------------------------------------------------------------------------

tick=$( t_tmpdir )
sh "${SEANCE}" repl --now > "${tick}/out" 2> "${tick}/err" < /dev/null
tick_rc=$?

t_is "${tick_rc}" "1" "the tick fails: its only heir is unreachable (TEST-NET-1)"

SYS_DS="${POOL}/seance-sys"
SYS_MP="${SEANCE_STATE_DIR}/sys"

if [ -f "${SYS_MP}/${V}/rc.conf_${V}" ]; then
    t_ok "and the mirror carries the VM's rc.conf, because its sysdir does not travel"
else
    t_not_ok "and the mirror carries the VM's rc.conf, because its sysdir does not travel"
    find "${SYS_MP}" -maxdepth 2 2>&1 | sed -e 's/^/# /'
fi

t_is "$( sha256 -q "${SYS_MP}/${V}/rc.conf_${V}" 2>/dev/null )" \
    "$( sha256 -q "${RCFILE}" )" \
    "byte-identical to the one CBSD wrote -- data path and all"

# ---------------------------------------------------------------------------
# The successor's half
#
# A peer would have received these snapshots into <standby_root>/<home>/. There
# is no peer, so the same sends are received here, into exactly those paths,
# with the engine's own receive flags (the shadow-mount law: D-65).
# ---------------------------------------------------------------------------

SNAP=$( zfs list -H -o name -t snapshot -r "${VMDS}" | tail -1 )
SYS_SNAP=$( zfs list -H -o name -t snapshot -r "${SYS_DS}" | tail -1 )

t_like "${SNAP}" "^${VMDS}@seance-${SHAPEB_NODE}-[0-9]{8}T[0-9]{6}Z\$" \
    "the tick snapshotted the VM's dataset with the wire protocol's name"

REPLICA="${POOL}/standby/${SHAPEB_NODE}/${V}"
SYS_REPLICA="${POOL}/standby/${SHAPEB_NODE}/seance-sys"

zfs create -o canmount=off -o mountpoint=none "${POOL}/standby" 2>/dev/null
zfs create -o canmount=off -o mountpoint=none "${POOL}/standby/${SHAPEB_NODE}" \
    2>/dev/null

# shellcheck disable=SC2329
#   Invoked through the harness's `t_rc ... -- <command>` form below, which
#   static analysis cannot see.
recv_one()
{
    local _snap _into _rc _send

    _snap=$1
    _into=$2
    _send=$( t_tmpdir )/send.rc

    ( zfs send "${_snap}"; echo $? > "${_send}" ) |
        zfs recv -s -u -x mountpoint -x canmount "${_into}"
    _rc=$?

    [ "$( cat "${_send}" )" = "0" ] || return 1
    [ "${_rc}" -eq 0 ] || return 1

    zfs set canmount=noauto "${_into}"
}

t_rc 0 "the VM's snapshot is received into <standby_root>/<home>/<guest>" \
    -- recv_one "${SNAP}" "${REPLICA}"
t_rc 0 "and the configuration mirror's into <standby_root>/<home>/seance-sys" \
    -- recv_one "${SYS_SNAP}" "${SYS_REPLICA}"

t_is "$( zfs get -H -o value,source mountpoint "${REPLICA}" | awk '{ print $2 }' )" \
    "inherited" "the replica inherits its mountpoint rather than owning one"

# Now this node is the survivor: the guest is unregistered here and its own
# copy is out of the way, exactly as it would be on a node that never had it.
t_rc 0 "the guest is unregistered here, as it would be on a survivor" \
    -- adapter_guest_unregister "${V}"
zfs unmount "${VMDS}" 2>/dev/null
zfs set mountpoint=none "${VMDS}" || t_diag "hiding the original failed"

# ---------------------------------------------------------------------------
# Rung 6's own steps, against the replica
# ---------------------------------------------------------------------------

PROMOTE_DEAD=${SHAPEB_NODE}
PROMOTE_TMPDIR=$( t_tmpdir )/promote
mkdir -p "${PROMOTE_TMPDIR}"

# The replica's disks are FILES, so its tree carries no volumes -- and this is
# what the ceremony reads a type from, because the shape of the disks is what
# decides which symlinks the platform needs. The platform's own word for the
# guest is "bhyve"; the two are different facts and the ladder now says so
# instead of aborting on the difference.
t_stdout_is "jail" \
    "the replica's DATASETS have the shape of a jail: no zvols, like every guest on the fleet" \
    -- promote_guest_type "${REPLICA}"

MP_OUT=$( t_tmpdir )/mountpath.out
promote_mount_path "${V}" jail "${REPLICA}" "${SYS_REPLICA}" "${PROMOTE_TMPDIR}" \
    > "${MP_OUT}" 2>&1
MP_RC=$?

t_is "${MP_RC}" "0" "promote_mount_path answers"
t_is "${PROMOTE_MOUNT_PATH}" "${VMDATA}" \
    "with the path the guest's OWN configuration names, read before anything is mounted"
t_is "${PROMOTE_CONFIG_SOURCE}" "${SYS_REPLICA}" \
    "out of the dead node's configuration mirror, which is where this layout's VM keeps it"
t_isnt "${PROMOTE_MOUNT_PATH}" "${WD}/vm/${V}" \
    "and NOT where this platform creates a VM, which is what a derivation would have said"
t_isnt "${PROMOTE_MOUNT_PATH}" "${WD}/jails-data/${V}-data" \
    "and NOT where it creates a jail either: neither convention could have produced this path"

t_is "$( zfs get -H -o value,source mountpoint "${SYS_REPLICA}" | awk '{ print $2 }' )" \
    "inherited" "and the mirror it borrowed is inherited again afterwards"

t_rc 0 "the mount ceremony puts the replica there" \
    -- promote_mount_ceremony "${V}" "${REPLICA}" "${PROMOTE_MOUNT_PATH}"

t_is "$( mount -p | awk -v p="${VMDATA}" '$2 == p { print $1 }' )" "${REPLICA}" \
    "and it really is mounted at the path its configuration named"

t_rc 0 "relinking a guest whose disks are files asks for no symlinks at all" \
    -- promote_relink "${V}" "${REPLICA}" jail "${PROMOTE_MOUNT_PATH}"

# The configuration, restored the way rung 6 restores it, into the plain
# directory this layout keeps it in.
# THE FLEET'S OWN TRAP (D-187): the survivor already holds ${jailsysdir}/<V> --
# on a clustered platform every node keeps one per cluster guest -- with a
# readable rc.conf and a local.sqlite the platform cannot read. Here the
# directory is the one this file made above, so it is made STALE the way the
# fleet's was: the rc.conf names an older data path, the database is not one.
STALE_SYSDIR="${WD}/jails-system/${V}"
sed -i '' -e "s|^data=.*|data=\"${WD}/vm/${V}-STALE\";|" "${STALE_SYSDIR}/rc.conf_${V}" ||
    t_diag "staling the sysdir's rc.conf failed"
printf 'not a database\n' > "${STALE_SYSDIR}/local.sqlite"
rm -f "${STALE_SYSDIR}/local.sqlite-wal" "${STALE_SYSDIR}/local.sqlite-shm"

t_rc 1 "a readable rc.conf in a sysdir OUTSIDE the replica does not count as travelled" \
    -- promote_config_travelled "${V}" "${REPLICA}"

t_rc 0 "the configuration is restored out of the mirror" \
    -- promote_sys_restore "${V}" "${SYS_REPLICA}" "${WD}/jails-system/${V}" \
    "${PROMOTE_TMPDIR}"

t_is "$( awk -F'"' '/^data=/ { print $2; exit }' "${STALE_SYSDIR}/rc.conf_${V}" )" "${VMDATA}" \
    "and the mirror's rc.conf is written OVER the stale one"
t_isnt "$( head -c 14 "${STALE_SYSDIR}/local.sqlite" )" "not a database" \
    "and so is the platform's per-guest database, which is what bls reads"
t_rc 0 "the database the mirror brought is one the platform can open" \
    -- sqlite3 "file:${STALE_SYSDIR}/local.sqlite?mode=ro&immutable=1" ".tables"
BAK=""; for _b in "${SEANCE_STATE_DIR}/sysdir-backup/${V}."*; do [ -d "${_b}" ] && BAK=${_b}; done
t_is "$( head -c 14 "${BAK}/local.sqlite" 2>/dev/null )" "not a database" \
    "and the survivor's stale copy was backed up first, outside the platform's view"

t_rc 0 "and CBSD registers the guest from it" \
    -- adapter_guest_register "${V}" "${RCFILE}"

# THE CHECK THAT USED TO FALSE-ALARM HERE. The replica's datasets look like a
# jail and the platform has just registered a bhyve; the old comparison was
# against where this platform CREATES a bhyve guest -- ${workdir}/vm/<name> --
# which is not where any guest on the fleet lives, so it would have stopped
# every promotion there after registering the guest. What is compared now is
# what the platform SAYS about this guest's data.
t_stdout_is "bhyve" "the platform calls the promoted guest a bhyve guest" \
    -- adapter_guest_type "${V}"
t_stdout_is "${VMDATA}" \
    "and it looks for its data exactly where the replica is mounted -- the check rung 6 makes" \
    -- adapter_guest_data_path "${V}"
t_stdout_is "${REPLICA}" \
    "so the platform's own answer now resolves to the REPLICA, promoted in place" \
    -- adapter_guest_datasets "${V}"

# ---------------------------------------------------------------------------
# RE-HOMED, against real CBSD (D-184)
# ---------------------------------------------------------------------------
#
# The registration a promotion reads is the DEAD node's copy, and it names that
# node. CBSD believes the field: register 2c's rc.conf on 2b and the guest is
# filed as 2c's, listed with an empty emulator on a clustered node, and skipped
# by adapter_guest_list as "not local to this node" -- so seance loses the
# guest it just promoted. Found on the fleet by drill-guest, 2026-08-24.
#
# Registering through the ADAPTER (not through cbsd directly, as the rows above
# do) must leave the platform calling this guest ours.
# First the FLEET'S OWN CASE: a bhyve VM left in CBSD's unregistered area on a
# survivor (raw junregister leaves the rc.conf export behind, and bls lists the
# entry out of that export alone). The node must still be able to count its
# own guests -- on the fleet this state produced "0 guests, 1 failures" and a
# stopped replication (D-185).
t_rc 0 "raw junregister leaves the VM in the unregistered area" \
    -- shapeb_cbsd junregister jname="${V}" inter=0
t_diag "raw bls rows: $( shapeb_cbsd bls header=0 display=jname,emulator,astart,status 2>/dev/null | tr '\n' '|' )"
t_diag "raw jls rows: $( shapeb_cbsd jls header=0 display=jname,emulator,astart,status 2>/dev/null | tr '\n' '|' )"
t_rc 0 "adapter_guest_list still succeeds with an unregistered VM in the listing" \
    -- adapter_guest_list
t_unlike "$( adapter_guest_list 2>/dev/null )" "^${V}	" \
    "and the unregistered VM is skipped, not listed and not counted"
rm -f "${WD}/jails-rcconf/rc.conf_${V}"

# From ${RCFILE}, not ${DUMP}: jregister MOVED the dump into
# ${jailsysdir}/<n>/ (jregister:215, asserted above), so ${DUMP} no longer
# exists by this point in the file. Copying from a path that is not there left
# the fixture registering CBSD from a one-line file and calling the defaults
# that came back a product defect -- which they were not.
FOREIGN=$( t_tmpdir )/rc.conf_foreign
[ -r "${RCFILE}" ] || t_diag "no landed registration at ${RCFILE}"
cp "${RCFILE}" "${FOREIGN}" || t_diag "copying the registration failed"
t_like "$( cat "${FOREIGN}" 2>/dev/null )" '^emulator="bhyve"' \
    "the fixture's copy really is the guest's whole registration, not a fragment"
sed -i '' -e "s|^nodename=.*|nodename=\"a-node-that-is-not-this-one\";|" "${FOREIGN}" ||
    t_diag "editing the nodename failed"
grep -q '^nodename="a-node-that-is-not-this-one";' "${FOREIGN}" ||
    printf 'nodename="a-node-that-is-not-this-one";\n' >> "${FOREIGN}"

t_stdout_is "a-node-that-is-not-this-one" \
    "the fixture really does hand the adapter a registration naming another node" \
    -- sh -c "awk -F'\"' '/^nodename=/ { print \$2; exit }' '${FOREIGN}'"

t_rc 0 "the adapter registers a guest from a configuration that names another node" \
    -- adapter_guest_register "${V}" "${FOREIGN}"

t_stdout_is "$( adapter_fact nodename )" \
    "and CBSD's own record of it now names THIS node, because registering is re-homing" \
    -- sh -c "awk -F'\"' '/^nodename=/ { print \$2; exit }' \
        '$( adapter_fact jailsysdir )/${V}/rc.conf_${V}'"

t_stdout_is "bhyve" \
    "so the platform can still say what it is -- the row that failed on the fleet" \
    -- adapter_guest_type "${V}"
t_stdout_is "${VMDATA}" \
    "and where its data is, which is what promote checks its own work against" \
    -- adapter_guest_data_path "${V}"

# ---------------------------------------------------------------------------
# Put it back
# ---------------------------------------------------------------------------

adapter_guest_unregister "${V}" > /dev/null 2>&1
zfs unmount "${REPLICA}" > /dev/null 2>&1
zfs inherit mountpoint "${REPLICA}" > /dev/null 2>&1
zfs destroy -r "${POOL}/standby" > /dev/null 2>&1

shapeb_down_and_check

t_done
