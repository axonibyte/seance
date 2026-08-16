#!/bin/sh
# Tier 5 -- a real jail through its whole life, and the two resolutions.
#
# tests/conformance/vectors.tsv is read-only by construction: the mutating
# verbs appear in it only with names their contracts must refuse. This file is
# the other half -- the one that starts, holds, refuses, releases, stops,
# unregisters and re-registers a jail CBSD really made -- and it is where the
# assertions M0 and M1 could only read out of source get run:
#
#   * D-21's LEVER: a jail in slave mode refuses `cbsd jstart`. The whole boot
#     gate rests on this one sentence and until now nobody had watched it
#     happen. Asserted three ways: the refusal's exit code, its message, and
#     that the jail is STILL NOT RUNNING afterwards -- the last of which is the
#     only one that would catch a CBSD that printed a refusal and started the
#     guest anyway.
#   * D-47's LIVENESS: `cbsd jstatus jname=<n> invert=1` for a guest that
#     EXISTS exits 0 and prints its jid, non-zero when it is running
#     (docs/cbsd-module-notes.md §6, "UNVERIFIED live until tier 5").
#   * D-71's DATASET RESOLUTION: the mounted path first, the pool derivation
#     second, on a real pool -- with a real replica standing in for a promoted
#     guest, at the mountpoint CBSD expects (D-44 item 4).
#   * The REGISTER ROUND TRIP: ${jailsysdir}/<n>/rc.conf_<n> is what
#     `cbsd jregister rcfile=` takes, which is the whole reason D-82 makes
#     seance carry that directory itself.
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
    echo "t_lifecycle_real: must run as root" >&2
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

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/adapter.subr
. "${T_ROOT}/${SEANCE_ADAPTER:-lib/adapter.subr}"

J=${SHAPEB_JAIL}
WD=$( shapeb_workdir )
SYSDIR="${WD}/jails-system/${J}"
RCFILE="${SYSDIR}/rc.conf_${J}"
POOL=$( zfs list -H -o name "${WD}/jails-data" )
DATAPATH="${WD}/jails-data/${J}-data"

t_plan 48

# ---------------------------------------------------------------------------
# Start, and what CBSD says about a guest that exists
# ---------------------------------------------------------------------------

t_rc 0 "adapter_guest_start starts a real jail" -- adapter_guest_start "${J}"

t_stdout_is "1" "a started jail is running" -- adapter_guest_running "${J}"

# The raw command, not only the adapter's reading of it: this is the sentence
# docs/cbsd-module-notes.md §6 marks UNVERIFIED, and it is about jstatus.
jid=$( shapeb_cbsd jstatus jname="${J}" invert=1 )
jrc=$?
t_is "${jrc}" "0" "cbsd jstatus invert=1 exits 0 for a guest that EXISTS"
case "${jid}" in
    ''|*[!0123456789]*) t_not_ok "and prints a jid"; t_diag "printed [${jid}]" ;;
    0)                  t_not_ok "and prints a NON-ZERO jid while it runs"
                        t_diag "printed [${jid}]" ;;
    *)                  t_ok "and prints a non-zero jid while it runs" ;;
esac

t_is "$( jls -h name 2>/dev/null | awk -v j="${J}" 'NR > 1 && $1 == j' )" "${J}" \
    "the kernel agrees there is a jail of that name (jls(8))"

# The listing, with its running column, for the guest the estate is made of.
# type, astart, status, running -- the four fields after the name. astart is 0
# because the substrate created it that way; status 1 is CBSD's "On"; running 1
# is the per-guest jstatus probe adapter_guest_list makes rather than reading
# the status column, which is the whole point of that column existing.
t_is "$( adapter_guest_list | awk -F '\t' -v j="${J}" '$1 == j { print $2, $3, $4, $5 }' )" \
    "jail 0 1 1" "adapter_guest_list reports it as a running, unheld jail"

t_rc 0 "adapter_guest_stop stops it" -- adapter_guest_stop "${J}"
t_stdout_is "0" "a stopped jail is not running" -- adapter_guest_running "${J}"

# ---------------------------------------------------------------------------
# D-21, live: slave mode is a veto
# ---------------------------------------------------------------------------

t_rc 0 "adapter_guest_hold puts it in slave mode" -- adapter_guest_hold "${J}"
t_stdout_is "1" "and the adapter reads it back as held" -- adapter_guest_held "${J}"
t_is "$( shapeb_cbsd jls header=0 display=jname,status jname="${J}" |
    awk -v j="${J}" '$1 == j { print $2 }' )" "Slave" \
    "CBSD's own listing calls it Slave (subr/strings.subr:27-46)"

held_dir=$( t_tmpdir )
adapter_guest_start "${J}" > "${held_dir}/out" 2> "${held_dir}/err"
held_rc=$?

t_is "${held_rc}" "1" "adapter_guest_start REFUSES a held guest (D-21)"
t_like "$( cat "${held_dir}/err" )" 'jstart' \
    "and says which command refused, on stderr"
t_is "$( cat "${held_dir}/out" )" "" \
    "and prints nothing on stdout: this function answers with its status"

# CBSD's own words, captured separately so that a change of wording is visible
# rather than merely a failed grep somewhere else.
refusal=$( shapeb_cbsd jstart jname="${J}" inter=0 2>&1 )
t_like "${refusal}" 'slave mode' \
    "cbsd jstart itself says 'slave mode' (sudoexec/jstart:367)"

# The assertion that matters most: the refusal was real.
t_stdout_is "0" "and the held jail is STILL not running" \
    -- adapter_guest_running "${J}"

t_rc 0 "adapter_guest_release puts it back to master" \
    -- adapter_guest_release "${J}"
t_stdout_is "0" "and the adapter reads it back as not held" \
    -- adapter_guest_held "${J}"
t_rc 0 "a released guest starts" -- adapter_guest_start "${J}"
t_stdout_is "1" "and is running" -- adapter_guest_running "${J}"
t_rc 0 "and stops again" -- adapter_guest_stop "${J}"

# ---------------------------------------------------------------------------
# Unregister and register: the round trip a promotion is made of
# ---------------------------------------------------------------------------

before_row=$( adapter_guest_list | awk -F '\t' -v j="${J}" '$1 == j' )
before_rc=$( sha256 -q "${RCFILE}" )

t_rc 0 "adapter_guest_unregister removes it from CBSD's database" \
    -- adapter_guest_unregister "${J}"

t_rc 1 "an unregistered guest is not a guest this node has" \
    -- adapter_guest_type "${J}"
t_rc 1 "and jstatus does not know it either" \
    -- adapter_guest_running "${J}"

t_is "$( adapter_guest_list | awk -F '\t' -v j="${J}" '$1 == j' )" "" \
    "and it is not in the estate listing"

t_is "$( sha256 -q "${RCFILE}" )" "${before_rc}" \
    "junregister leaves \${jailsysdir}/<n>/rc.conf_<n> byte-identical"

# WHERE CBSD PUTS ITS OWN DUMP, which is not where seance reads from.
# junregister --help: "rcfile= <path>, alternative path to source config file,
# by default: ${workdir}/jails-rcconf/rc.conf_<env>". Observed: that file is
# created by the unregister and is NOT removed by the register that follows.
if [ -f "${WD}/jails-rcconf/rc.conf_${J}" ]; then
    t_ok "junregister dumped its own copy to \${workdir}/jails-rcconf/rc.conf_<n>"
else
    t_not_ok "junregister dumped its own copy to \${workdir}/jails-rcconf/rc.conf_<n>"
fi

t_rc 1 "adapter_guest_register refuses an rcfile it cannot read" \
    -- adapter_guest_register "${J}" /nonexistent/rc.conf
t_rc 0 "adapter_guest_register brings it back from the sysdir's rcfile" \
    -- adapter_guest_register "${J}" "${RCFILE}"

t_is "$( adapter_guest_list | awk -F '\t' -v j="${J}" '$1 == j' )" "${before_row}" \
    "and the guest is listed again with exactly the fields it had"

# THE PHANTOM. jregister does not remove the dump junregister made, and jls
# lists ${jailrcconfdir} as an "Unregister" area of its own (jailctl/jls:281-296)
# -- so CBSD now prints TWO rows for one guest, and its jname= predicate does
# not reach the second one. The adapter has to be right about this or an estate
# listing gains a guest that does not exist.
t_is "$( shapeb_cbsd jls header=0 display=jname,status jname="${J}" | wc -l |
    tr -d ' ' )" "2" \
    "CBSD lists the guest twice after the round trip: registered and Unregister"
t_stdout_is "jail" "the adapter still answers about the registered one" \
    -- adapter_guest_type "${J}"
t_rc 1 "and a question about another name is not answered with this row" \
    -- adapter_guest_type nosuchguest

rm -f "${WD}/jails-rcconf/rc.conf_${J}"
t_is "$( shapeb_cbsd jls header=0 display=jname,status jname="${J}" | wc -l |
    tr -d ' ' )" "1" \
    "removing the dump removes the phantom row"

t_rc 0 "a re-registered jail starts" -- adapter_guest_start "${J}"
t_stdout_is "1" "and runs" -- adapter_guest_running "${J}"
t_rc 0 "and stops" -- adapter_guest_stop "${J}"

# ---------------------------------------------------------------------------
# D-71, live: the mounted path first, the pool derivation second
#
# A guest promoted IN PLACE keeps its dataset under <standby_root>/<dead>/<name>
# and is given CBSD's expected mountpoint (D-44 item 4). Nothing derived from
# the pool that holds jails-data could name it, so the adapter asks the mount
# table first. Here that replica is made for real -- send and receive on this
# pool -- and put where a promotion would have put it.
# ---------------------------------------------------------------------------

HOME_DS="${POOL}/${J}"
STANDBY="${POOL}/standby"
REPLICA="${STANDBY}/alpha/${J}"

zfs snapshot "${HOME_DS}@t5" || t_diag "could not snapshot ${HOME_DS}"
zfs create -o canmount=off -o mountpoint=none "${STANDBY}" 2>/dev/null
zfs create -o canmount=off -o mountpoint=none "${STANDBY}/alpha" 2>/dev/null

# The engine's own flags: `zfs send -p` per dataset (D-64) into
# `zfs recv -s -u -x mountpoint -x canmount`, then canmount=noauto enforced on
# what arrived (D-65, repl_remote_enforce_law). Reproduced rather than
# approximated, because the state the replica is in is precisely what the
# resolution below is being asked about.
send_rc=$( t_tmpdir )/send.rc
( zfs send -p "${HOME_DS}@t5"; echo $? > "${send_rc}" ) |
    zfs recv -s -u -x mountpoint -x canmount "${REPLICA}"
recv_rc=$?
t_is "$( cat "${send_rc}" )-${recv_rc}" "0-0" \
    "a replica of the jail's dataset is received under the standby tree"

zfs set canmount=noauto "${REPLICA}" || t_diag "could not enforce canmount"
t_is "$( zfs get -H -o value,source mountpoint "${REPLICA}" | awk '{ print $2 }' )" \
    "inherited" "and it carries no mountpoint of its own (the shadow-mount law)"

# The origin gets out of the way exactly as a promotion's origin would: its
# mountpoint goes back to none and it is not mounted.
zfs unmount "${HOME_DS}" 2>/dev/null
zfs set mountpoint=none "${HOME_DS}" ||
    t_diag "could not unmount the home dataset"

# The mount ceremony D-44 item 4 describes: CBSD's expected path, canmount
# already noauto, and an EXPLICIT mount. Nothing in seance mounts by accident.
zfs set "mountpoint=${DATAPATH}" "${REPLICA}" || t_diag "could not point the replica"
zfs mount "${REPLICA}" || t_diag "could not mount the replica"

t_is "$( mount -p | awk -v p="${DATAPATH}" '$2 == p { print $1 }' )" "${REPLICA}" \
    "and it is mounted where CBSD expects this guest's data"

t_stdout_is "${REPLICA}" \
    "adapter_guest_datasets names the REPLICA, not the pool derivation (D-71)" \
    -- adapter_guest_datasets "${J}"

# Now the fallback, and the guard that makes it safe. With nothing mounted at
# the path, `zfs list <path>` answers with the dataset CONTAINING it -- which
# on this node is CBSD's whole workdir dataset. An adapter without the
# exact-mountpoint check would snapshot, send and remount the entire estate.
zfs unmount "${REPLICA}" || t_diag "could not unmount the replica"
zfs set mountpoint=none "${REPLICA}" || t_diag "could not unpoint the replica"

t_is "$( zfs list -H -o name "${DATAPATH}" )" "${POOL}" \
    "with nothing mounted there, zfs list <path> answers with the CONTAINING dataset"

zfs set "mountpoint=${DATAPATH}" "${HOME_DS}" || t_diag "could not repoint home"
zfs mount "${HOME_DS}" 2>/dev/null

t_stdout_is "${HOME_DS}" \
    "and with the home dataset back, the resolution names it again" \
    -- adapter_guest_datasets "${J}"

# The fallback proper: unmount the home dataset too, so NOTHING is mounted at
# the path, and check the answer is still the guest's own dataset.
zfs unmount "${HOME_DS}" 2>/dev/null
t_stdout_is "${HOME_DS}" \
    "unmounted, it falls back to <pool>/<name> and not to the workdir dataset" \
    -- adapter_guest_datasets "${J}"

zfs mount "${HOME_DS}" 2>/dev/null
zfs destroy -r "${STANDBY}" 2>/dev/null
zfs destroy "${HOME_DS}@t5" 2>/dev/null

# ---------------------------------------------------------------------------
# The guest is left as it was found
# ---------------------------------------------------------------------------

shapeb_down_and_check

t_done
