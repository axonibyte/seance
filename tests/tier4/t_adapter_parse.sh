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

t_plan 17

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

t_done
