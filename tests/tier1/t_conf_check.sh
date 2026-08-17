#!/bin/sh
# Tier 1 -- conf_check: every rule has a fixture that breaks it.
#
# A validator is only worth what its failing cases prove. Every rule below gets
# a config that violates exactly it, and the assertion is that the rule fires;
# the committed sample is the positive control at the top, so a rule that has
# started firing on a perfectly good file also shows up here.
#
# The verdict line is asserted as well as the problem lines. It is the last
# line on purpose -- it survives a scrollback, and it is what
# 'seance config --check' hands back as its own verdict rather than printing a
# second one that could one day disagree with it.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/conf.subr
. "${T_ROOT}/lib/conf.subr"

DIR=$( t_tmpdir )
N=0

# A two-node config that passes, to which each fixture adds its own fault.
GOOD='node_alpha_nodename=alpha.example.net
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_bravo_nodename=bravo.example.net
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha'

# rule <name> <expected problem substring> -- extra config lines on stdin
#
# Builds GOOD plus the lines given, loads it, and asserts both that the check
# fails and that it fails for the stated reason. Two assertions per rule: a
# check that fails for the wrong reason is not the check being tested.
rule()
{
    local _name _want _f _out

    _name=$1
    _want=$2
    N=$(( N + 1 ))
    _f="${DIR}/rule${N}.conf"

    printf '%s\n' "${GOOD}" > "${_f}"
    cat >> "${_f}"

    if ! conf_load "${_f}"; then
        t_not_ok "${_name}: fixture parses"
        t_not_ok "${_name}"
        return 0
    fi
    t_ok "${_name}: fixture parses"

    if _out=$( conf_check ); then
        t_not_ok "${_name}"
        t_diag "conf_check passed a config it should have rejected"
        t_diag "${_out}"
        return 0
    fi

    t_like "${_out}" "${_want}" "${_name}"
}

t_plan 126

# --- the positive control --------------------------------------------------

t_rc 0 "the committed sample parses" -- \
    conf_load "${T_ROOT}/etc/seance.conf.sample"
t_stdout_is "PASS" "the committed sample passes the check" -- conf_check
t_rc 0 "and the check exits 0" -- conf_check

printf '%s\n' "${GOOD}" > "${DIR}/good.conf"
conf_load "${DIR}/good.conf" || t_diag "good.conf failed to load"
t_stdout_is "PASS" "the two-node base fixture passes" -- conf_check

# --- cluster size ----------------------------------------------------------

printf '' > "${DIR}/nonodes.conf"
conf_load "${DIR}/nonodes.conf" || t_diag "nonodes.conf failed to load"
t_like "$( conf_check )" 'problem: no nodes are configured' \
    "a config with no nodes fails"
t_rc 1 "and exits 1" -- conf_check

cat > "${DIR}/onenode.conf" <<'EOF'
node_alpha_nodename=alpha.example.net
node_alpha_mgmt=alpha-mgmt.example.net
EOF
conf_load "${DIR}/onenode.conf" || t_diag "onenode.conf failed to load"
t_like "$( conf_check )" \
    'problem: only one node is configured: a witness-less cluster of one is not a cluster' \
    "a cluster of one is not a cluster"

# --- required node fields --------------------------------------------------

rule "a node without a nodename fails" \
    'problem: node charlie: node_charlie_nodename is required' <<'EOF'
node_charlie_mgmt=charlie-mgmt.example.net
EOF

rule "a node without a mgmt address fails" \
    'problem: node charlie: node_charlie_mgmt is required' <<'EOF'
node_charlie_nodename=charlie.example.net
EOF

rule "a nodename with a space in it fails" \
    'problem: node charlie: nodename must be a single non-empty word' <<'EOF'
node_charlie_nodename=charlie one
node_charlie_mgmt=charlie-mgmt.example.net
EOF

rule "a mgmt address with a space in it fails" \
    'problem: node charlie: mgmt must be a single non-empty word' <<'EOF'
node_charlie_nodename=charlie.example.net
node_charlie_mgmt=charlie mgmt
EOF

rule "two node keys claiming one nodename fails" \
    'problem: node charlie: nodename "alpha.example.net" is claimed by more than one node key' <<'EOF'
node_charlie_nodename=alpha.example.net
node_charlie_mgmt=charlie-mgmt.example.net
EOF

# --- succession ------------------------------------------------------------

rule "an heir that is not a configured node fails" \
    'problem: node charlie: heir "delta" is not a configured node' <<'EOF'
node_charlie_nodename=charlie.example.net
node_charlie_mgmt=charlie-mgmt.example.net
node_charlie_heir=delta
EOF

rule "a node that is its own heir fails" \
    'problem: node charlie: heir is the node itself' <<'EOF'
node_charlie_nodename=charlie.example.net
node_charlie_mgmt=charlie-mgmt.example.net
node_charlie_heir=charlie
EOF

rule "a node that is its own second heir fails" \
    'problem: node charlie: heir2 is the node itself' <<'EOF'
node_charlie_nodename=charlie.example.net
node_charlie_mgmt=charlie-mgmt.example.net
node_charlie_heir=alpha
node_charlie_heir2=charlie
EOF

rule "the same node named as both heirs fails" \
    'problem: node charlie: heir and heir2 are the same node' <<'EOF'
node_charlie_nodename=charlie.example.net
node_charlie_mgmt=charlie-mgmt.example.net
node_charlie_heir=alpha
node_charlie_heir2=alpha
EOF

rule "a second heir with no first heir fails" \
    'problem: node charlie: heir2 is set without an heir' <<'EOF'
node_charlie_nodename=charlie.example.net
node_charlie_mgmt=charlie-mgmt.example.net
node_charlie_heir2=alpha
EOF

rule "a guest heir that is not a configured node fails" \
    'problem: guest db01: heir "delta" is not a configured node' <<'EOF'
guest_db01_heir=delta
EOF

rule "a guest heir2 with no guest heir fails" \
    'problem: guest db01: heir2 is set without an heir' <<'EOF'
guest_db01_heir2=alpha
EOF

# --- integer ranges --------------------------------------------------------

rule "a cadence below the floor fails" \
    'problem: cadence: 30 is outside 60\.\.86400' <<'EOF'
cadence=30
EOF

rule "a cadence above the ceiling fails" \
    'problem: cadence: 90000 is outside 60\.\.86400' <<'EOF'
cadence=90000
EOF

rule "a cadence that is not a number fails" \
    'problem: cadence: "often" is not a non-negative integer' <<'EOF'
cadence=often
EOF

rule "a negative cadence fails" \
    'problem: cadence: "-60" is not a non-negative integer' <<'EOF'
cadence=-60
EOF

rule "an ssh port of zero fails" \
    'problem: ssh_port: 0 is outside 1\.\.65535' <<'EOF'
ssh_port=0
EOF

rule "an ssh port above 65535 fails" \
    'problem: ssh_port: 65536 is outside 1\.\.65535' <<'EOF'
ssh_port=65536
EOF

rule "a fence_timeout of zero fails" \
    'problem: fence_timeout: 0 is outside 1\.\.3600' <<'EOF'
fence_timeout=0
EOF

rule "a skew tolerance beyond an hour fails" \
    'problem: skew_tolerance: 3601 is outside 0\.\.3600' <<'EOF'
skew_tolerance=3601
EOF

rule "a debounce that is not a number fails" \
    'problem: debounce: "soon" is not a non-negative integer' <<'EOF'
debounce=soon
EOF

rule "a retention_recent below the floor fails" \
    'problem: retention_recent: 30 is outside 60\.\.31536000' <<'EOF'
retention_recent=30
EOF

# --- cross-field consistency ----------------------------------------------

rule "a staleness_max below the cadence fails" \
    'problem: fleet: staleness_max 600 is below cadence 900' <<'EOF'
cadence=900
staleness_max=600
EOF

rule "a retention_hourly below retention_recent fails" \
    'problem: fleet: retention_hourly 3600 is below retention_recent 14400' <<'EOF'
retention_hourly=3600
EOF

rule "a guest staleness_max below its own cadence fails" \
    'problem: guest db01: staleness_max 300 is below cadence 3600' <<'EOF'
guest_db01_cadence=3600
guest_db01_staleness_max=300
EOF

rule "a guest cadence outside the range fails" \
    'problem: guest db01: cadence: 10 is outside 60\.\.86400' <<'EOF'
guest_db01_cadence=10
EOF

# --- the optional strings --------------------------------------------------

rule "notify_cmd set to nothing fails" \
    'problem: notify_cmd is set to nothing' <<'EOF'
notify_cmd=
EOF

rule "an empty ssh_user fails" \
    'problem: ssh_user must be a single non-empty word' <<'EOF'
ssh_user=
EOF

rule "an ssh_user with a space fails" \
    'problem: ssh_user must be a single non-empty word' <<'EOF'
ssh_user=root admin
EOF

rule "an empty witness fails" \
    'problem: witness must be a single non-empty word' <<'EOF'
witness=
EOF

rule "an empty standby_root fails" \
    'problem: standby_root must be a single non-empty word' <<'EOF'
standby_root=
EOF

rule "an empty display name fails" \
    'problem: names_alpha must be a single non-empty word' <<'EOF'
names_alpha=
EOF

# --- fencing keys, shape only ---------------------------------------------

rule "a fence_driver that is not [a-z0-9_]+ fails" \
    'problem: node alpha: fence_driver "IPMI-2" is not' <<'EOF'
node_alpha_fence_driver=IPMI-2
node_alpha_fence_target=alpha-bmc.example.net
EOF

rule "an empty fence_driver fails" \
    'problem: node alpha: fence_driver "" is not' <<'EOF'
node_alpha_fence_driver=
node_alpha_fence_target=alpha-bmc.example.net
EOF

rule "a fence_target without a driver fails" \
    'problem: node alpha: fence_target is set without a fence_driver' <<'EOF'
node_alpha_fence_target=alpha-bmc.example.net
EOF

rule "a fence_target with a space fails" \
    'problem: node alpha: fence_target must be a single non-empty word' <<'EOF'
node_alpha_fence_driver=ipmi
node_alpha_fence_target=alpha bmc
EOF

# A well-formed pair of fencing keys is accepted, because the point of the
# rules above is shape and not the presence of fencing, which M1 does not use.
cat > "${DIR}/fence-ok.conf" <<EOF
${GOOD}
node_alpha_fence_driver=ipmi
node_alpha_fence_target=alpha-bmc.example.net
EOF
conf_load "${DIR}/fence-ok.conf" || t_diag "fence-ok.conf failed to load"
t_stdout_is "PASS" "well-formed fencing keys are accepted" -- conf_check

# --- CARP: the vhids, and who may act on whose death ------------------------
#
# Every rule here is about an arrangement that would otherwise be believed and
# not be true: a vhid two nodes share, a vhid with no address, an automatic
# promotion a node is not in the succession for. None of them stops seance
# working; all of them stop it working the way the file says.

rule "a vhid outside 1..255 fails" \
    'problem: node alpha: vhid "0" is not a CARP vhid' <<'EOF'
carp_interface=vtnet0
node_alpha_vhid=0
node_alpha_vhid_ip=192.0.2.101/32
EOF

rule "a vhid that is not a number fails" \
    'problem: node alpha: vhid "one" is not a CARP vhid' <<'EOF'
carp_interface=vtnet0
node_alpha_vhid=one
node_alpha_vhid_ip=192.0.2.101/32
EOF

rule "two nodes claiming one vhid fails" \
    'problem: node bravo: vhid 7 is claimed by more than one node' <<'EOF'
carp_interface=vtnet0
node_alpha_vhid=7
node_alpha_vhid_ip=192.0.2.101/32
node_bravo_vhid=7
node_bravo_vhid_ip=192.0.2.102/32
EOF

rule "a vhid without an address fails" \
    'problem: node alpha: vhid is set without a vhid_ip' <<'EOF'
carp_interface=vtnet0
node_alpha_vhid=1
EOF

rule "an address without a vhid fails" \
    'problem: node alpha: vhid_ip is set without a vhid' <<'EOF'
carp_interface=vtnet0
node_alpha_vhid_ip=192.0.2.101/32
EOF

rule "a vhid_ip with no prefix length fails" \
    'problem: node alpha: vhid_ip "192.0.2.101" is not <dotted-quad>/<prefix-length>' <<'EOF'
carp_interface=vtnet0
node_alpha_vhid=1
node_alpha_vhid_ip=192.0.2.101
EOF

rule "a vhid_ip with a bad octet fails" \
    'problem: node alpha: vhid_ip "192.0.2.256/32" is not <dotted-quad>' <<'EOF'
carp_interface=vtnet0
node_alpha_vhid=1
node_alpha_vhid_ip=192.0.2.256/32
EOF

# inet_aton(3) reads a leading-zero octet as octal, so 010 is 8 and the
# operator's file means something other than what it says.
rule "a vhid_ip octet with a leading zero fails" \
    'problem: node alpha: vhid_ip "010.0.2.101/32" is not <dotted-quad>' <<'EOF'
carp_interface=vtnet0
node_alpha_vhid=1
node_alpha_vhid_ip=010.0.2.101/32
EOF

rule "a vhid_ip with a prefix length over 32 fails" \
    'problem: node alpha: vhid_ip "192.0.2.101/33" is not <dotted-quad>' <<'EOF'
carp_interface=vtnet0
node_alpha_vhid=1
node_alpha_vhid_ip=192.0.2.101/33
EOF

rule "a vhid with no carp_interface anywhere fails" \
    'problem: node alpha: carries a vhid and nothing says which interface' <<'EOF'
node_alpha_vhid=1
node_alpha_vhid_ip=192.0.2.101/32
EOF

# ... and the per-node override satisfies it, which is the only way a fleet
# whose nodes name their interfaces differently can be expressed at all.
cat > "${DIR}/carp-perif.conf" <<'EOF'
node_alpha_nodename=alpha.example.net
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_alpha_vhid=1
node_alpha_vhid_ip=192.0.2.101/32
node_alpha_carp_interface=epair0b
node_bravo_nodename=bravo.example.net
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
node_bravo_vhid=2
node_bravo_vhid_ip=192.0.2.102/32
node_bravo_carp_interface=epair1b
EOF
conf_load "${DIR}/carp-perif.conf" || t_diag "carp-perif.conf failed to load"
t_stdout_is "PASS" \
    "a per-node carp_interface satisfies the requirement, with no fleet key at all" \
    -- conf_check

rule "a per-node carp_interface with a space in it fails" \
    'problem: node alpha: carp_interface must be a single non-empty word' <<'EOF'
node_alpha_carp_interface=vtnet0 vtnet1
EOF

rule "a carp_interface with a space in it fails" \
    'problem: carp_interface must be a single non-empty word' <<'EOF'
carp_interface=vtnet0 vtnet1
EOF

rule "a carp_pass with a space in it fails" \
    'problem: carp_pass must be a single non-empty word' <<'EOF'
carp_pass=two words
EOF

rule "auto outside 0..1 fails" \
    'problem: auto: 2 is outside 0..1' <<'EOF'
auto=2
EOF

rule "auto_promote naming a node that does not exist fails" \
    'problem: node bravo: auto_promote names "delta", which is not a configured node' <<'EOF'
node_bravo_auto_promote=delta
EOF

rule "auto_promote naming the node itself fails" \
    'problem: node bravo: auto_promote names the node itself' <<'EOF'
node_bravo_auto_promote=bravo
EOF

# The rule that matters most: a node may only auto-promote a peer it is in the
# succession for. GOOD has alpha_heir=bravo and bravo_heir=alpha, so charlie is
# in the succession for neither.
rule "auto_promote for a node this one is not heir to fails" \
    'problem: node charlie: auto_promote names alpha, but charlie is neither node_alpha_heir nor node_alpha_heir2' <<'EOF'
carp_interface=vtnet0
node_charlie_nodename=charlie.example.net
node_charlie_mgmt=charlie-mgmt.example.net
node_alpha_vhid=1
node_alpha_vhid_ip=192.0.2.101/32
node_charlie_auto_promote=alpha
EOF

rule "auto_promote for a node with no vhid fails" \
    'problem: node bravo: auto_promote names alpha, which has no node_alpha_vhid' <<'EOF'
node_bravo_auto_promote=alpha
EOF

# The positive control: a ring with CARP arranged and one heir relationship
# armed -- which is exactly what design §12 says M3 ships -- validates.
cat > "${DIR}/carp-ok.conf" <<'EOF'
carp_interface=vtnet0
carp_pass=notthepassword
auto=1
node_alpha_nodename=alpha.example.net
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_alpha_vhid=1
node_alpha_vhid_ip=192.0.2.101/32
node_bravo_nodename=bravo.example.net
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
node_bravo_vhid=2
node_bravo_vhid_ip=192.0.2.102/32
node_bravo_auto_promote=alpha
EOF
conf_load "${DIR}/carp-ok.conf" || t_diag "carp-ok.conf failed to load"
t_stdout_is "PASS" "a CARP-configured, half-armed fleet validates" -- conf_check

# A second heir may be armed too, and the two words of an auto_promote list are
# each checked: the membership test refuses a multi-word needle (D-86), so a
# list has to be walked word by word or it would validate by accident.
cat > "${DIR}/carp-two.conf" <<'EOF'
carp_interface=vtnet0
node_alpha_nodename=alpha.example.net
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_alpha_heir2=charlie
node_alpha_vhid=1
node_alpha_vhid_ip=192.0.2.101/32
node_bravo_nodename=bravo.example.net
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=charlie
node_bravo_heir2=alpha
node_bravo_vhid=2
node_bravo_vhid_ip=192.0.2.102/32
node_charlie_nodename=charlie.example.net
node_charlie_mgmt=charlie-mgmt.example.net
node_charlie_heir=alpha
node_charlie_heir2=bravo
node_charlie_vhid=3
node_charlie_vhid_ip=192.0.2.103/32
node_charlie_auto_promote=alpha bravo
EOF
conf_load "${DIR}/carp-two.conf" || t_diag "carp-two.conf failed to load"
t_stdout_is "PASS" \
    "a two-word auto_promote validates when this node is in both successions" -- \
    conf_check

# And the same list with one word wrong is caught on that word alone.
cat > "${DIR}/carp-two-bad.conf" <<'EOF'
carp_interface=vtnet0
node_alpha_nodename=alpha.example.net
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_alpha_heir2=charlie
node_alpha_vhid=1
node_alpha_vhid_ip=192.0.2.101/32
node_bravo_nodename=bravo.example.net
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=charlie
node_bravo_heir2=alpha
node_bravo_vhid=2
node_bravo_vhid_ip=192.0.2.102/32
node_charlie_nodename=charlie.example.net
node_charlie_mgmt=charlie-mgmt.example.net
node_charlie_heir=alpha
node_charlie_heir2=bravo
node_charlie_vhid=3
node_charlie_vhid_ip=192.0.2.103/32
node_alpha_auto_promote=bravo delta
EOF
conf_load "${DIR}/carp-two-bad.conf" || t_diag "carp-two-bad.conf failed to load"
out=$( conf_check )
t_like "${out}" 'auto_promote names "delta", which is not a configured node' \
    "the bad word of a two-word auto_promote is named"
t_unlike "${out}" 'auto_promote names "bravo"' \
    "and the good word beside it is not"

# --- the verdict line ------------------------------------------------------

cat > "${DIR}/three.conf" <<EOF
${GOOD}
cadence=30
ssh_port=0
notify_cmd=
EOF
conf_load "${DIR}/three.conf" || t_diag "three.conf failed to load"
out=$( conf_check )
t_like "${out}" '^FAIL: 3 problems$' "the verdict counts the problems"
t_is "$( printf '%s\n' "${out}" | tail -n 1 )" "FAIL: 3 problems" \
    "the verdict is the last line"
t_is "$( printf '%s\n' "${out}" | grep -c '^problem: ' )" "3" \
    "one line per problem, and no more"

# The check is repeatable: running it twice must not accumulate the first run's
# problems into the second. Run in THIS shell, redirected to files -- through a
# command substitution each call gets its own subshell and the accumulation
# this is looking for could never happen, which would make the assertion look
# green and mean nothing.
conf_check > "${DIR}/check1"
conf_check > "${DIR}/check2"
t_is "$( cat "${DIR}/check2" )" "$( cat "${DIR}/check1" )" \
    "conf_check is repeatable in one shell"
t_is "$( cat "${DIR}/check1" )" "${out}" \
    "and gives the same answer as it did through a subshell"

t_done
