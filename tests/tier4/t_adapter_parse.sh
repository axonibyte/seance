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
    ROWS=$( printf '%s\n' "$1" | _adapter_list_rows 2> "${DIR}/err" )
    RRC=$?
}

t_plan 47

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
    local _jname

    _jname=""
    for _a in "$@"; do
        case "${_a}" in jname=*) _jname=${_a#jname=} ;; esac
    done

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

# The fixture zfs answers the same way the real one does.
t_is "$( zfs list -H -o name /wd/jails-data/web01-data )" "pool0/web01" \
    "the fixture resolves an exact mountpoint to its own dataset"
t_is "$( zfs list -H -o name /wd/jails-data/off01-data )" "pool0/cbsd" \
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

# --- the paths the platform expects ------------------------------------------
t_is "$( adapter_guest_mountpoint web01 jail )" "/wd/jails-data/web01-data" \
    "a jail belongs at \${jaildatadir}/<name>-data (sudoexec/mkdatadir:20-21)"
t_is "$( adapter_guest_mountpoint db01 bhyve )" "/wd/vm/db01" \
    "a bhyve guest belongs at \${workdir}/vm/<name> (sudoexec/bcreate:579)"
t_rc 2 "a guest type this platform does not support is a contract error" \
    -- adapter_guest_mountpoint web01 xen

t_is "$( adapter_guest_links web01 jail )" "" \
    "a jail needs no symlinks: its dataset mounts where CBSD looks"
t_is "$( adapter_guest_links db01 bhyve )" "/wd/jails-system/db01	/wd/vm/db01
/wd/jails-data/db01-data	/wd/vm/db01" \
    "a bhyve guest needs both of CBSD's own links (sudoexec/bcreate:598-599)"

# --- both layouts, through the resolution that has to tell them apart --------
t_is "$( adapter_guest_datasets web01 )" "pool0/web01
pool0/web01/data" \
    "a guest at home resolves through its mounted path, children and all"

t_is "$( adapter_guest_datasets arc01 )" "pool0/standby/alpha/arc01" \
    "a guest PROMOTED IN PLACE resolves to its replica under the standby tree"

t_is "$( adapter_guest_datasets db01 )" "pool0/vmhost/db01
pool0/vmhost/db01/dsk1.vhd" \
    "a VM resolves through \${workdir}/vm/<name>, zvols included"

t_is "$( adapter_guest_datasets off01 )" "pool0/cbsd/off01" \
    "a guest whose dataset is not mounted falls back to the pool derivation rather than to the workdir dataset the path resolves to"

t_rc 1 "a guest this node does not have has no datasets" \
    -- adapter_guest_datasets gone01

t_done
