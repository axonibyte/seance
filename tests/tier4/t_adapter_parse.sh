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

t_plan 29

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

# shellcheck disable=SC2329
#   Called by lib/adapter.subr, which shellcheck checks as a separate file.
_adapter_cbsd()
{
    case "$1 ${2:-}" in
        "emulator web01") printf 'jail\n' ;;
        "emulator arc01") printf 'jail\n' ;;
        "emulator off01") printf 'jail\n' ;;
        "emulator db01")  printf 'bhyve\n' ;;
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
