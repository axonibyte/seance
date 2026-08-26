#!/bin/sh
# Tier 4 -- the real adapter's parsers, fed injected listings.
#
# lib/adapter.subr cannot be RUN on the workstation: it needs CBSD, and tier 5
# (reaper, shape B) is where it meets it. But the part of it that will break
# first when CBSD changes an output convention is not the invocation, it is the
# READING -- and that part is pure, takes text on stdin, and can be shown the
# exact shapes CBSD 15.0.9 produces without CBSD being anywhere near.
#
# So this file injects listings rather than faults: same tier, same idea, one
# layer lower. The fixtures below are the shapes cited in lib/adapter.subr's
# comments -- whitespace-aligned columns from `column -t`, status as a word
# (subr/strings.subr:27-46), the "Unregister" row from jls's unregistered area
# (jailctl/jls:287-295), and both spellings of ifconfig's carp line.
#
# NOTHING HERE MAY CALL A FUNCTION THAT REACHES adapter_init. On a workstation
# that happens to have CBSD configured -- this one does -- adapter_init
# succeeds, and a test that printed what it found would be a test that printed
# the operator's real node name into a public repository's logs. Only the
# leading-underscore parsers are called here, and none of them initialises
# anything.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/adapter.subr
. "${T_ROOT}/lib/adapter.subr"

DIR=$( t_tmpdir )

# rows <listing-text>  -- run the listing parser, keeping stdout and status.
ROWS=""
RRC=0
rows()
{
    # THE SKIP MEMO IS CLEARED FIRST, so that each fixture below is its own
    # process as far as the diagnostics are concerned. A skip line is said once
    # per process (the dedupe section at the end of this file is about that),
    # and these fixtures are about the PARSING -- a row of one that went quiet
    # because a fixture three screens up had already said the same sentence
    # would be a test measuring the memo by accident.
    rm -f "$( _adapter_skip_log )"

    ROWS=$( printf '%s\n' "$1" | _adapter_list_rows 2> "${DIR}/err" )
    RRC=$?
}

t_plan 104

# --- a listing of the shape CBSD prints --------------------------------------
rows 'web01  jail   1  On
db01   bhyve  1  Off
arc01  jail   0  Slave
mnt01  jail   1  Maintenance'

t_is "${ROWS}" "web01	jail	1	1
db01	bhyve	1	0
arc01	jail	0	2
mnt01	jail	1	3" "the status word is turned back into CBSD's status integer"
t_is "${RRC}" "0" "a well-formed listing exits 0"

# A CRASHED GUEST comes back mid-recovery, and CBSD decorates its status word
# with a substate: `Maintenance:Stopping_VM` (D-191). The mode is what the guest
# IS; the substate is informational. Reading it as UNREADABLE is what made the
# boot gate fail open -- adapter_guest_list refused the whole listing and the
# estate autostarted ungated.
t_is "$( _adapter_status_int Maintenance:Stopping_VM )" "3" \
    "a compound status reads as its mode -- Maintenance:Stopping_VM is Maintenance (3)"
t_is "$( _adapter_status_int On:Something )" "1" \
    "and the rule is the mode, not the substate: On:Something is On (1)"
t_rc 2 "but a genuinely unknown MODE is still Unknown, substate or not" -- \
    _adapter_status_int Frobnicate:whatever
rows 'web01  jail   1  On
mnt01  bhyve  1  Maintenance:Stopping_VM'
t_is "${ROWS}" "web01	jail	1	1
mnt01	bhyve	1	3" "and a listing that carries a mid-recovery guest still parses whole"
t_is "${RRC}" "0" "so the estate can be enumerated while the platform recovers a crash"

# --- an empty listing is an answer -------------------------------------------
ROWS=$( printf '' | _adapter_list_rows )
RRC=$?
t_is "${ROWS}" "" "an empty listing produces no rows"
t_is "${RRC}" "0" "an empty listing is not an error: a node may have no guests"

# --- rows that are understood but out of scope are skipped, loudly -----------
rows 'web01  jail            1  On
qe01   qemu-arm-static  1  Off'
t_is "${ROWS}" "web01	jail	1	1" "an unsupported emulator is left out"
t_is "${RRC}" "0" "an unsupported emulator does not fail the listing"
t_like "$( cat "${DIR}/err" )" 'skipping qe01' \
    "an unsupported emulator is named on stderr, not passed over in silence"

# A CLUSTERED NODE'S LISTING (D-171), which is what a real fleet produces and
# what this file had never been shown. `cbsd jls`/`cbsd bls` turn the foreign
# listing on by themselves in cluster mode (jailctl/jls:70-77), and the remote
# rows arrive with fields CBSD could not fill -- printed as "0" by bls
# (bhyvectl/bls:220-222) and as "-" by jls (jailctl/jls:169-171).
#
# THE ROW IS STILL SKIPPED, and the whole listing still succeeds. Both halves
# matter: the emulator check comes before the status check, and a remote row's
# status field is that same unfillable "0" -- a parser that reached it would
# call the listing a contract error and this node would stop replicating
# ANYTHING the moment a peer joined the cluster.
rows 'web01  jail   1  On
db01   bhyve  1  Off
far01  0      0  0
far02  -      0  -'

t_is "${ROWS}" "web01	jail	1	1
db01	bhyve	1	0" "another node's guests are left out of this node's roster"
t_is "${RRC}" "0" \
    "and a clustered listing is NOT a contract error, however many remote rows it carries"
t_like "$( cat "${DIR}/err" )" 'skipping far01: it is not local to this node' \
    "the skip says what it means -- not \"emulator 0 is not supported by seance\", which reads as a product gap on every clustered node"
t_like "$( cat "${DIR}/err" )" 'skipping far02: it is not local to this node' \
    "and jls's spelling of the same empty field is read the same way"
t_unlike "$( cat "${DIR}/err" )" 'emulator 0 is not supported' \
    "and the old sentence is gone, because it was never true of these rows"

# CBSD'S OWN ERROR TEXT, ON ITS OWN STDOUT (D-185).
#
# This is verbatim what a real node printed into the middle of a listing when
# a guest's ${jailsysdir}/<n>/local.sqlite could not be read. Four fields fall
# out of it -- Unable/to/fetch/vm -- so every length check passes, and before
# this row the parser called "to" an unsupported emulator, skipped it, and
# RETURNED SUCCESS. The listing that line appeared in was also SHORT: the two
# guests that node hosted were missing from it, seance reported
# "0 guests, 0 warnings, 0 failures", and their replication stopped for twelve
# and a half hours with nothing said.
rows 'Unable  to  fetch  vm  data  from:  /usr/jails/jails-system/db01/local.sqlite
web01   jail   1  On'
t_is "${RRC}" "2" \
    "a line that is not a guest row is a CONTRACT ERROR, not a guest called Unable"
t_unlike "${ROWS}" 'Unable' \
    "and no guest is invented from it"
t_like "$( cat "${DIR}/err" )" 'LISTING CONTAINS A LINE THAT IS NOT A GUEST' \
    "the diagnostic says what it found"
t_like "$( cat "${DIR}/err" )" 'may be SHORT' \
    "and says the consequence that matters: what follows may be missing"
t_unlike "$( cat "${DIR}/err" )" 'emulator to is not supported' \
    "and never calls a word of CBSD's prose an emulator"

# A row carrying MORE than the four fields asked for is the same kind of
# untrustworthy: the listing is not the shape this adapter reads.
rows 'web01  jail  1  On  extra-field-nobody-asked-for'
t_is "${RRC}" "2" "a row with a fifth field is a contract error"

# A REAL unsupported emulator still says exactly that: the two cases are
# different facts and the diagnostic may not blur them.
rows 'web01  jail             1  On
qe01   qemu-riscv64-static  1  Off'
t_like "$( cat "${DIR}/err" )" 'emulator qemu-riscv64-static is not supported by seance' \
    "an emulator seance really does not support is still named as one"
t_unlike "$( cat "${DIR}/err" )" 'not local to this node' \
    "and is not blamed on the cluster"

rows 'web01  jail  1  On
old01  jail  1  Unregister'
t_is "${ROWS}" "web01	jail	1	1" "an unregistered guest is left out"
t_like "$( cat "${DIR}/err" )" 'skipping old01' \
    "an unregistered guest is named on stderr"

# --- rows that are NOT understood fail the whole listing ---------------------
# A guest missing from an estate listing is a guest a promotion leaves behind,
# so an unreadable row is never a quiet skip.
rows 'web01  jail  1  On
huh01  jail  1  Unknown'
t_is "${RRC}" "2" "a status CBSD itself calls Unknown is a contract error"

rows 'web01  jail  1'
t_is "${RRC}" "2" "a row with a field missing is a contract error"

rows 'WEB01  jail  1  On'
t_is "${RRC}" "2" "a guest name seance cannot use is a contract error"

rows 'web01  jail  yes  On'
t_is "${RRC}" "2" "an astart that is not 0 or 1 is a contract error"

# --- ifconfig's carp line, both spellings ------------------------------------
# /usr/src/sbin/ifconfig/carp.c:86-90 prints the state and the vhid; what comes
# after the advskew has changed between releases, and neither spelling may be
# missed.
t_is "$( printf '%s\n' '	carp: MASTER vhid 3 advbase 1 advskew 0
	      peer 224.0.0.18 peer6 ff02::12' | _adapter_carp_scan 3 )" \
    "MASTER" "the current ifconfig spelling is read"

t_is "$( printf '%s\n' '	carp: BACKUP vhid 1 advbase 1 advskew 0, peer 224.0.0.18' |
    _adapter_carp_scan 1 )" \
    "BACKUP" "the older ifconfig spelling is read too"

t_is "$( printf '%s\n' '	carp: MASTER vhid 30 advbase 1 advskew 0' |
    _adapter_carp_scan 3 )" \
    "" "vhid 30 is not vhid 3"

t_is "$( printf '%s\n' '	vrrp: MASTER vrid 7 prio 100 interval 100' |
    _adapter_carp_scan 7 )" \
    "vrrp" "a vhid running VRRPv3 is reported as such, not as CARP"

# ---------------------------------------------------------------------------
# Dataset resolution: the mounted path first, the pool derivation second
#
# A guest promoted IN PLACE keeps living under the standby tree and is mounted
# where CBSD expects its data (D-44 item 4), so a derivation from the pool that
# holds jails-data can no longer name it. The adapter therefore asks the mount
# table first -- and that question has a trap in it, which the guard row below
# is the whole reason this section exists: `zfs list <path>` answers with the
# dataset CONTAINING the path, not only with one mounted exactly there
# (observed on FreeBSD 15.0: `zfs list -H -o name,mountpoint /data/jails`
# prints the parent dataset and /data). Without the exact-mountpoint check a
# guest whose dataset happened to be unmounted would resolve to CBSD's whole
# workdir dataset.
#
# ADAPTER_* is set here directly rather than through adapter_init, for the
# reason at the top of this file: adapter_init succeeds on a workstation that
# has CBSD and would put the operator's real node name in a public log.
# ---------------------------------------------------------------------------

ZWORLD=$( t_tmpdir )/world
cat > "${ZWORLD}" <<'EOF'
pool0/cbsd	/wd
pool0/cbsd/off01	none
pool0/web01	/wd/jails-data/web01-data
pool0/web01/data	/wd/jails-data/web01-data/data
pool0/vmhost/db01	/wd/vm/db01
pool0/vmhost/db01/dsk1.vhd	-
pool0/standby/alpha/arc01	/wd/jails-data/arc01-data
pool0/cbsd/jails-data	/wd/jails-data
pool0/cbsd/jails-data/vm01-data	/wd/jails-data/vm01-data
EOF

ZBIN=$( t_tmpdir )/bin
mkdir -p "${ZBIN}"

cat > "${ZBIN}/zfs" <<'EOF'
#!/bin/sh
# zfs(8), reduced to the three questions lib/adapter.subr asks it, answered
# from a table of "<dataset><TAB><mountpoint>". Path resolution reproduces the
# real thing: the CONTAINING dataset, longest mountpoint prefix wins.
set -u
w=${ZFS_WORLD}

case "$*" in
    "list -H -o name -t filesystem,volume -r "*|"list -H -r -o name -t filesystem,volume "*)
        d=${*##* }
        awk -F '\t' -v d="${d}" '$1 == d || index($1, d "/") == 1 { print $1 }' "${w}" |
            grep . || exit 1
        exit 0
        ;;
    "get -H -o value mountpoint "*)
        d=${*##* }
        awk -F '\t' -v d="${d}" '$1 == d { print $2; found = 1 } END { exit !found }' "${w}" ||
            exit 1
        exit 0
        ;;
    "list -H -o name "*)
        a=${*##* }
        case "${a}" in
            /*)
                awk -F '\t' -v p="${a}" '
                    $2 == "none" || $2 == "-" { next }
                    $2 == p { if (length($2) > best) { best = length($2); n = $1 } ; next }
                    index(p, $2 "/") == 1 { if (length($2) > best) { best = length($2); n = $1 } }
                    END { if (n == "") { exit 1 } ; print n }
                ' "${w}" || exit 1
                ;;
            *)
                awk -F '\t' -v d="${a}" '$1 == d { print $1; found = 1 } END { exit !found }' \
                    "${w}" || exit 1
                ;;
        esac
        exit 0
        ;;
esac

echo "zfs: this fixture does not answer: $*" >&2
exit 2
EOF
chmod 0755 "${ZBIN}/zfs"

ZFS_WORLD=${ZWORLD}
export ZFS_WORLD
PATH="${ZBIN}:${PATH}"
export PATH

# The listings _adapter_guest_row reads, in the shape CBSD prints them, with
# the two traps tier 5 found in the real thing built in:
#
#   * `cbsd jls jname=<x>` also prints the WHOLE unregistered area, which its
#     jname= predicate does not reach (jailctl/jls:281-296) -- so every jls
#     answer below carries old01's leftover row, whatever was asked for;
#   * a VM is invisible to jls and a jail to bls (jailctl/jls:244,
#     bhyvectl/bls:367), so the caller has to ask both.
#
# shellcheck disable=SC2329
#   Called by lib/adapter.subr, which shellcheck checks as a separate file.
_adapter_cbsd()
{
    local _jname _display

    _jname=""
    for _a in "$@"; do
        case "${_a}" in jname=*) _jname=${_a#jname=} ;; esac
    done

    _display=""
    for _a in "$@"; do
        case "${_a}" in display=*) _display=${_a#display=} ;; esac
    done

    # `display=jname,data` is a listing of its own shape, and the fixture
    # answers it the way a real node does: the guest's OWN recorded data path,
    # whatever convention made it (D-171(b)). vm01 is the fleet's shape
    # verbatim -- a bhyve VM at the jail-shaped path -- and db01 is the shape
    # sudoexec/bcreate:595 produces. off01's is a path with no dataset of its
    # own, and old01's field was never filled, which CBSD prints as "0".
    if [ "${_display}" = "jname,data" ]; then
        case "$1" in
            jls)
                case "${_jname}" in
                    web01) printf 'web01  /wd/jails-data/web01-data\n' ;;
                    arc01) printf 'arc01  /wd/jails-data/arc01-data\n' ;;
                    off01) printf 'off01  /wd/jails-data/off01-data\n' ;;
                esac
                printf 'old01  0\n'
                ;;
            bls)
                case "${_jname}" in
                    db01)  printf 'db01   /wd/vm/db01\n' ;;
                    vm01)  printf 'vm01   /wd/jails-data/vm01-data\n' ;;
                    far01) printf 'far01  0\n' ;;
                esac
                ;;
            *) return 1 ;;
        esac
        return 0
    fi

    case "$1" in
        jls)
            case "${_jname}" in
                web01) printf 'web01  jail   1  On\n' ;;
                arc01) printf 'arc01  jail   0  Slave\n' ;;
                off01) printf 'off01  jail   1  Off\n' ;;
            esac
            printf 'old01  jail   1  Unregister\n'
            printf 'OLD02  jail   1  Unregister\n'
            ;;
        bls)
            case "${_jname}" in
                db01) printf 'db01   bhyve  1  Off\n' ;;
                vm01) printf 'vm01   bhyve  1  Off\n' ;;
            esac
            ;;
        # CBSD's mutating verbs talk on STDOUT, refusals included -- `cbsd
        # jstart` on a jail in slave mode prints "Jail in slave mode..."
        # through err() (sudoexec/jstart:367). Reproduced here so that a
        # [no output] function which let that through would fail at
        # workstation speed rather than in tier 5.
        jstart|jstop|jswmode|jregister|junregister)
            printf 'cbsd says something on stdout\n'
            [ "$1" = "jstart" ] && [ "${_jname}" = "arc01" ] && return 1
            return 0
            ;;
        *) return 1 ;;
    esac
}

ADAPTER_READY=1
ADAPTER_WORKDIR=/wd
ADAPTER_JAILDATADIR=/wd/jails-data
ADAPTER_JAILSYSDIR=/wd/jails-system
# A real one, because the unregister rows below act on it.
ADAPTER_JAILRCCONFDIR="${DIR}/jails-rcconf"
mkdir -p "${ADAPTER_JAILRCCONFDIR}"

# The fixture zfs answers the same way the real one does.
t_is "$( zfs list -H -o name /wd/jails-data/web01-data )" "pool0/web01" \
    "the fixture resolves an exact mountpoint to its own dataset"
t_is "$( zfs list -H -o name /wd/jails-data/off01-data )" "pool0/cbsd/jails-data" \
    "and a path with no dataset of its own to the dataset CONTAINING it, as zfs does"

# --- the guest's own listing row: type and held ------------------------------
#
# Both of these used to go through `cbsd emulator <name>`, which cannot answer
# on FreeBSD 15.1: tools/emulator:13 quotes its SQL literal with double quotes,
# and SQLite 3.53.3 rejects those, so CBSD's builtin returns empty with rc 0 and
# the command says "No such instance" about a jail that exists. Found by tier 5
# against a real jail; these rows are what would have caught it here.

t_stdout_is "jail" "a jail's type is read from its own listing row" \
    -- adapter_guest_type web01
t_stdout_is "bhyve" "a VM's type is found in bls, which is asked after jls" \
    -- adapter_guest_type db01
t_stdout_is "jail" "a held guest still has a type" \
    -- adapter_guest_type arc01

t_rc 1 "an unregistered guest is not a guest this node can be asked about" \
    -- adapter_guest_type old01
t_rc 1 "a name no listing carries is rc 1" -- adapter_guest_type gone01
t_rc 2 "a name seance will not put on a command line is rc 2" \
    -- adapter_guest_type WEB01

# The name filter, on its own. jls answers every query with the whole
# unregistered area (jailctl/jls:281-296), so a question about one guest
# arrives carrying other guests' rows -- including, on a real node, rows for
# names CBSD allows and seance does not, since validate_jname accepts upper
# case (subr/nc.subr:733-737) and junregister leaves a file behind for every
# guest ever unregistered. OLD02 above is such a row.
#
# Both halves matter. Without the filter the second one FAILS: _adapter_list_rows
# calls an unusable name a contract error, so one stale rc.conf for a guest
# seance cannot name would make every question about every OTHER guest answer
# rc 2.
t_rc 1 "a per-guest listing is filtered by name, not trusted to be" \
    -- _adapter_guest_row nosuchguest
t_stdout_is "jail" \
    "and another guest's unusable leftover row does not break this guest's answer" \
    -- adapter_guest_type web01

t_stdout_is "1" "a guest in slave mode is held" -- adapter_guest_held arc01
t_stdout_is "0" "a guest at status 0 is not held" -- adapter_guest_held web01

# --- the [no output] verbs really produce none ------------------------------
#
# Every one of these runs a CBSD command that writes to stdout, and their
# contract marker is [no output]: stdout is data, and a caller that captured
# CBSD's progress chatter or its refusal would be reading a sentence as an
# answer. Found in tier 5, where adapter_guest_start on a held jail exited 1
# having printed "Jail in slave mode. Please cbsd jswmode mode=master first"
# on stdout.
t_stdout_is "" "adapter_guest_start prints nothing on stdout" \
    -- adapter_guest_start web01
t_stdout_is "" "adapter_guest_stop prints nothing on stdout" \
    -- adapter_guest_stop web01
t_stdout_is "" "adapter_guest_hold prints nothing on stdout" \
    -- adapter_guest_hold web01
t_stdout_is "" "adapter_guest_release prints nothing on stdout" \
    -- adapter_guest_release web01
t_stdout_is "" "adapter_guest_unregister prints nothing on stdout" \
    -- adapter_guest_unregister web01
t_stdout_is "" "adapter_guest_register prints nothing on stdout" \
    -- adapter_guest_register web01 "${DIR}/err"

# And a REFUSAL is still silent on stdout: the branch that matters, because it
# is the one whose message a caller is most likely to capture and act on.
t_stdout_is "" "a refused start prints nothing on stdout either" \
    -- adapter_guest_start arc01
t_rc 1 "and it is a refusal" -- adapter_guest_start arc01

# --- unregistering does not leave a phantom guest behind ----------------------
#
# `cbsd junregister` dumps the row it is deleting into
# ${jailrcconfdir}/rc.conf_<name> on its way out (sudoexec/junregister:128-146)
# and nothing ever removes it, because `cbsd jregister` MOVES the file it reads
# into ${jailsysdir}/<name>/ (sudoexec/jregister:215) and promote registers
# from the replica's copy, never from that one. jls then prints a row for it
# out of its unregistered area, outside every predicate (jailctl/jls:281-296) --
# so one failback made this node say "skipping <g>: CBSD's database does not
# know it" on every tick, every status and every gate, for ever. Observed on
# the real node (tier 5, docs/cbsd-module-notes.md §8.8); the OLD02 row in the
# jls fixture above is the same litter, left by an earlier round trip.
: > "${ADAPTER_JAILRCCONFDIR}/rc.conf_web01"
: > "${ADAPTER_JAILRCCONFDIR}/rc.conf_db01"
t_stdout_is "" "adapter_guest_unregister still prints nothing on stdout" \
    -- adapter_guest_unregister web01
t_is "$( ls "${ADAPTER_JAILRCCONFDIR}" )" "rc.conf_db01" \
    "the export junregister wrote is gone when the unregister returns, and only that guest's"

t_rc 0 "an unregister with nothing left behind is still a success" \
    -- adapter_guest_unregister web01

# A removal that cannot happen is a failed unregister, not a quiet one: the
# node is left listing a guest it does not have, and the caller has to hear it.
mkdir -p "${ADAPTER_JAILRCCONFDIR}/rc.conf_arc01/inuse"
t_rc 1 "an export that cannot be removed fails the unregister" \
    -- adapter_guest_unregister arc01
adapter_guest_unregister arc01 2> "${DIR}/unreg.err" > /dev/null
t_like "$( cat "${DIR}/unreg.err" )" 'could not be removed' \
    "and says so, naming the path, on stderr"

# --- the paths the platform expects ------------------------------------------
t_is "$( adapter_guest_mountpoint web01 jail )" "/wd/jails-data/web01-data" \
    "a jail belongs at \${jaildatadir}/<name>-data (sudoexec/mkdatadir:20-21)"
t_is "$( adapter_guest_mountpoint db01 bhyve )" "/wd/vm/db01" \
    "a bhyve guest belongs at \${workdir}/vm/<name> (sudoexec/bcreate:579)"
t_rc 2 "a guest type this platform does not support is a contract error" \
    -- adapter_guest_mountpoint web01 xen

# --- the links, which follow the DATA PATH and not a convention (D-181) ------
#
# CBSD links ${jailsysdir}/<n> and ${jaildatadir}/<n>-data to ${data}, whatever
# ${data} is (sudoexec/bcreate:594-599), so the ceremony passes the path it
# mounted the replica at and the adapter does not work one out for itself.
t_is "$( adapter_guest_links web01 jail /wd/jails-data/web01-data )" "" \
    "a jail needs no symlinks: its dataset mounts where CBSD looks"
t_is "$( adapter_guest_links db01 bhyve /wd/vm/db01 )" "/wd/jails-system/db01	/wd/vm/db01
/wd/jails-data/db01-data	/wd/vm/db01" \
    "a bhyve guest needs both of CBSD's own links (sudoexec/bcreate:598-599)"

# THE FLEET'S SHAPE AGAIN: a VM whose data IS ${jaildatadir}/<name>-data. The
# second link would then be its own target, and `ln -sf X X` on a mounted
# directory does not fail -- it puts a link inside it. CBSD only makes that
# link in the branch where the two differ (bcreate:594-598).
t_is "$( adapter_guest_links vm01 bhyve /wd/jails-data/vm01-data )" \
    "/wd/jails-system/vm01	/wd/jails-data/vm01-data" \
    "a link whose path is its own target is left out, and the other one is not"
t_rc 0 "and leaving it out is not a failure" \
    -- adapter_guest_links vm01 bhyve /wd/jails-data/vm01-data

t_rc 2 "a caller with no data path to pass is a contract error, not an empty list" \
    -- adapter_guest_links db01 bhyve
t_rc 2 "and a relative one is refused before anything is linked" \
    -- adapter_guest_links db01 bhyve vm/db01

# --- what the PLATFORM says about where a guest's data is --------------------
#
# The same field adapter_guest_datasets resolves through, now readable by the
# ceremony that has to check its own work: promote mounts a replica where the
# guest's configuration says, registers it, and then asks THIS.
t_stdout_is "/wd/jails-data/web01-data" \
    "the platform's data path for a jail is read from its own listing row" \
    -- adapter_guest_data_path web01
t_stdout_is "/wd/vm/db01" "and a VM's comes out of bls, which is asked second" \
    -- adapter_guest_data_path db01
t_stdout_is "/wd/jails-data/vm01-data" \
    "and the fleet's VM answers with the jail-shaped path it really lives at" \
    -- adapter_guest_data_path vm01
t_rc 1 "a guest whose data field was never filled (CBSD prints \"0\") is not a path" \
    -- adapter_guest_data_path old01
t_rc 1 "and neither is a clustered node's remote row (D-177)" \
    -- adapter_guest_data_path far01
t_rc 2 "a name seance will not put on a command line is a contract error" \
    -- adapter_guest_data_path WEB01

# --- what the GUEST'S OWN CONFIGURATION says, before anything is mounted -----
#
# This is the read the whole of D-181 turns on: the promotion ceremony has a
# replica and no registration, so the only thing that can say where the replica
# belongs is the file the platform is about to be handed to register it with.
# The shapes below are the ones `cbsd jmkrcconf` writes (jailctl/jmkrcconf:27-35:
# quoted values, trailing semicolons) and the token junregister leaves behind.
CFG="${DIR}/rcconf"
mkdir -p "${CFG}"

printf 'relative_path="1";\ndata="/wd/jails-data/web01-data";\nastart="1";\n' \
    > "${CFG}/rc.conf_web01"
t_stdout_is "/wd/jails-data/web01-data" \
    "a configuration in CBSD's own shape -- quoted, semicolon-terminated -- is read" \
    -- adapter_config_data_path "${CFG}/rc.conf_web01"

printf 'emulator="bhyve";\ndata="/wd/jails-data/vm01-data";\n' > "${CFG}/rc.conf_vm01"
t_stdout_is "/wd/jails-data/vm01-data" \
    "THE FLEET: a bhyve guest whose own configuration puts it on the jail-shaped path" \
    -- adapter_config_data_path "${CFG}/rc.conf_vm01"

printf 'data=/wd/vm/db01\n' > "${CFG}/rc.conf_db01"
t_stdout_is "/wd/vm/db01" "an unquoted value is the same value" \
    -- adapter_config_data_path "${CFG}/rc.conf_db01"

printf "data='/wd/vm/db02';\n" > "${CFG}/rc.conf_db02"
t_stdout_is "/wd/vm/db02" "and so is a single-quoted one" \
    -- adapter_config_data_path "${CFG}/rc.conf_db02"

# The platform's own token: junregister replaces the workdir with CBSDROOT
# (sudoexec/junregister:140-141) and jregister puts THIS node's workdir back
# before it registers anything (sudoexec/jregister:151, tools/replacewdir:22).
# A ceremony that mounted the literal token's path would mount somewhere the
# registration is not about.
printf 'data="CBSDROOT/jails-data/tok01-data";\n' > "${CFG}/rc.conf_tok01"
t_stdout_is "/wd/jails-data/tok01-data" \
    "CBSDROOT is resolved to this node's workdir, the way jregister resolves it" \
    -- adapter_config_data_path "${CFG}/rc.conf_tok01"

# A file the platform SOURCES: the last assignment is the one that takes
# effect (sudoexec/jregister:154), so the last is the one read.
printf 'data="/wd/vm/dup01";\ndata="/wd/jails-data/dup01-data";\n' \
    > "${CFG}/rc.conf_dup01"
t_stdout_is "/wd/jails-data/dup01-data" \
    "a repeated assignment is read the way sourcing it would read it: the last wins" \
    -- adapter_config_data_path "${CFG}/rc.conf_dup01"

# --- states no path: the LAST RESORT, not a refusal --------------------------
printf 'data="0";\n' > "${CFG}/rc.conf_zero01"
t_rc 1 "the schema's default (\"0\") states no data path (share/local-jails.schema:39)" \
    -- adapter_config_data_path "${CFG}/rc.conf_zero01"
printf 'astart="1";\n' > "${CFG}/rc.conf_none01"
t_rc 1 "and a configuration with no data key at all states none either" \
    -- adapter_config_data_path "${CFG}/rc.conf_none01"
printf 'data="";\n' > "${CFG}/rc.conf_empty01"
t_rc 1 "and so does an empty value" \
    -- adapter_config_data_path "${CFG}/rc.conf_empty01"

# --- states an unusable path: a REFUSAL, and never a fallback ----------------
#
# The difference matters: "it does not say" leaves the platform's convention as
# the best available answer, while "it says something seance will not mount a
# replica at" is a fact about THIS guest that a convention would paper over.
printf 'data="jails-data/rel01-data";\n' > "${CFG}/rc.conf_rel01"
t_rc 2 "a relative data path is a refusal: it resolves against whatever directory promote ran in" \
    -- adapter_config_data_path "${CFG}/rc.conf_rel01"
adapter_config_data_path "${CFG}/rc.conf_rel01" 2> "${DIR}/cfg.err" > /dev/null
t_like "$( cat "${DIR}/cfg.err" )" 'not a path a replica can be mounted at' \
    "and it says so, naming the file and the value"

printf 'data="/";\n' > "${CFG}/rc.conf_root01"
t_rc 2 "the root filesystem is not a place to mount a replica" \
    -- adapter_config_data_path "${CFG}/rc.conf_root01"

printf 'data="/wd/vm/two words";\n' > "${CFG}/rc.conf_space01"
t_rc 2 "a path with whitespace in it cannot survive a mountpoint property or a TSV record" \
    -- adapter_config_data_path "${CFG}/rc.conf_space01"

printf 'data="/wd/vm/../../etc";\n' > "${CFG}/rc.conf_dots01"
t_rc 2 "and a traversal is not a place CBSD ever put a guest" \
    -- adapter_config_data_path "${CFG}/rc.conf_dots01"

t_rc 2 "a configuration file that cannot be read is a contract error, not an absence" \
    -- adapter_config_data_path "${CFG}/nosuchfile"

# --- one line per skipped guest per PROCESS ----------------------------------
#
# `repl` enumerates the roster four times in one tick, and every enumeration
# used to say the same thing about the same skipped guest: four identical lines
# per tick, per guest, under cron, for ever. On a clustered node that is one
# line per tick for every guest of every peer. A diagnostic that is always
# there is a diagnostic nobody reads -- the same finding D-97 acted on for the
# phantom-guest line.
#
# The behaviour is unchanged and the rows are unchanged; what is asserted here
# is the COUNT, which is the whole of the fix, and the two things it must not
# cost: a second, different sentence about the same guest, and a memo that
# cannot be used going quiet instead of loud.

SKIPLOG=$( _adapter_skip_log )
rm -f "${SKIPLOG}"

CLUSTERED='web01  jail             1  On
far01  0                0  0
qe01   qemu-arm-static  1  Off'

: > "${DIR}/dedupe.err"
n=0
while [ "${n}" -lt 4 ]; do
    printf '%s\n' "${CLUSTERED}" | _adapter_list_rows \
        > "${DIR}/dedupe.out" 2>> "${DIR}/dedupe.err"
    n=$(( n + 1 ))
done

t_is "$( grep -c 'skipping far01' "${DIR}/dedupe.err" )" "1" \
    "four enumerations of the same roster say the remote guest's skip ONCE"
t_is "$( grep -c 'skipping qe01' "${DIR}/dedupe.err" )" "1" \
    "and the unsupported emulator's skip once, because every skip is deduped and not just one of them"
t_is "$( grep -c 'skipping' "${DIR}/dedupe.err" )" "2" \
    "so a tick that enumerates four times says two lines, not eight"
t_is "$( cat "${DIR}/dedupe.out" )" "web01	jail	1	1" \
    "and the ROWS are unchanged: this is what is said about a skip, never whether it happens"

# A different sentence about the SAME guest is a different fact and is still
# said: a guest whose row changed between two enumerations has something new to
# report, and a memo keyed on the name alone would have swallowed it.
printf 'far01  xen  1  Off\n' | _adapter_list_rows > /dev/null 2>> "${DIR}/dedupe.err"
t_like "$( cat "${DIR}/dedupe.err" )" 'skipping far01: emulator xen is not supported' \
    "a different sentence about the same guest is still said"

# A memo that is not a plain file is not this process's memo: /tmp is
# world-writable, and a symlink planted at the memo's path would otherwise make
# seance append its diagnostics through it. Refusing costs the line being said
# every time, which is the direction a failure here must fall in.
rm -f "${SKIPLOG}"
ln -sf "${DIR}/planted" "${SKIPLOG}"
: > "${DIR}/planted.err"
printf 'far02  0  0  0\n' | _adapter_list_rows > /dev/null 2>> "${DIR}/planted.err"
printf 'far02  0  0  0\n' | _adapter_list_rows > /dev/null 2>> "${DIR}/planted.err"

t_is "$( grep -c 'skipping far02' "${DIR}/planted.err" )" "2" \
    "a memo that cannot be used says the line every time rather than going quiet"
if [ -e "${DIR}/planted" ]; then
    t_not_ok "and nothing is written through the planted link"
else
    t_ok "and nothing is written through the planted link"
fi

rm -f "${SKIPLOG}"

# --- both layouts, through the resolution that has to tell them apart --------
t_is "$( adapter_guest_datasets web01 )" "pool0/web01
pool0/web01/data" \
    "a guest at home resolves through its mounted path, children and all"

t_is "$( adapter_guest_datasets arc01 )" "pool0/standby/alpha/arc01" \
    "a guest PROMOTED IN PLACE resolves to its replica under the standby tree"

t_is "$( adapter_guest_datasets db01 )" "pool0/vmhost/db01
pool0/vmhost/db01/dsk1.vhd" \
    "a VM resolves through \${workdir}/vm/<name>, zvols included"

# THE FLEET'S OWN SHAPE (D-171(b)), verbatim: a bhyve VM whose data lives at
# the jail-shaped path, in a dataset whose NAME carries the "-data" suffix. The
# derivation this resolver used to fall back to would have computed
# pool0/cbsd/vm01 and refused with "no dataset" -- for a guest sitting right
# there on disk, which is exactly what the fleet saw.
t_is "$( adapter_guest_datasets vm01 )" "pool0/cbsd/jails-data/vm01-data" \
    "a guest resolves through the data path CBSD RECORDED for it, whatever convention named the dataset"

# And the case that used to be answered with a computed name is now a refusal.
# A guest whose data path has no dataset of its own may not be replicated from
# a guess: the old fallback named <parent>/<name> and checked it against
# nothing, which is the shape of the fleet's failure and would be the shape of
# a silent wrong answer on any other layout.
t_rc 1 "a data path with no dataset of its own is a refusal, not a computed name" \
    -- adapter_guest_datasets off01
adapter_guest_datasets off01 2> "${DIR}/off01.err" > /dev/null
t_like "$( cat "${DIR}/off01.err" )" '/wd/jails-data/off01-data is inside pool0/cbsd/jails-data' \
    "and the refusal names the path, the dataset that contains it, and that seance will not guess"

t_rc 1 "a guest this node does not have has no datasets" \
    -- adapter_guest_datasets gone01

t_done
