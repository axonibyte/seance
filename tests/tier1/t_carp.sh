#!/bin/sh
# Tier 1 -- lib/carp.subr: the succession map, expressed as advskews.
#
# Everything in carp.subr except carp_devd_action is a pure function of the
# loaded configuration, which is what lets the whole rendering be driven here
# with no interfaces, no adapter, no root and no CARP. carp_devd_action needs
# one adapter fact and gets a stub for it -- the fact, not the adapter.
#
# WHAT IS BEING PINNED, and why each matters:
#
#   the advskews ARE the map (design §6). A node's own vhid at 0, the vhid of a
#   node it is heir to at 100, second heir at 200. Get that wrong in one
#   direction and CARP hands the estate to a node that is not the heir; get it
#   wrong in the other and the owner never gets its own identity back.
#
#   this node's OWN vhid gets no devd rule. Becoming MASTER for one's own
#   identity is what booting looks like; a rule for it would turn every reboot
#   into a promotion attempt against oneself.
#
#   the rc.conf variable name is NORMALISED. /etc/network.subr maps ".-/+" to
#   "_" before it looks a variable up, so a vlan interface's rendering has to
#   do the same or rc(8) reads a variable nobody wrote.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
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
# shellcheck source=../../lib/carp.subr
. "${T_ROOT}/lib/carp.subr"

# The one fact carp.subr asks a host for. Stubbed rather than mocked: what is
# under test is what the rendering does with the answer, not how the adapter
# arrives at it.
STUB_VERB="/usr/local/bin/platform seance"
# shellcheck disable=SC2329
#   Called by lib/carp.subr, which shellcheck checks as a separate file.
adapter_fact()
{
    case "${1:-}" in
        verb) printf '%s\n' "${STUB_VERB}" ;;
        *) return 2 ;;
    esac
}

DIR=$( t_tmpdir )

RING="carp_interface=vtnet0
carp_pass=notthepassword
auto=1

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
node_bravo_auto_promote=alpha

node_charlie_nodename=charlie.example.net
node_charlie_mgmt=charlie-mgmt.example.net
node_charlie_heir=alpha
node_charlie_heir2=bravo
node_charlie_vhid=3
node_charlie_vhid_ip=192.0.2.103/32"

t_plan 54

printf '%s\n' "${RING}" > "${DIR}/ring.conf"
t_rc 0 "the ring fixture parses" -- conf_load "${DIR}/ring.conf"
conf_load "${DIR}/ring.conf" || t_diag "ring.conf failed to load"
t_stdout_is "PASS" "and validates" -- conf_check

# --- the map -----------------------------------------------------------------

t_rc 0 "carp_configured says this fleet has vhids" -- carp_configured
t_stdout_is "vtnet0" "carp_interface falls back to the fleet's" -- \
    carp_interface bravo
t_rc 2 "and refuses to answer for no node at all" -- carp_interface
t_stdout_is "1" "alpha's vhid" -- carp_vhid alpha
t_stdout_is "192.0.2.101/32" "and the address it carries" -- carp_vhid_ip alpha
t_stdout_is "alpha" "vhid 1 maps back to alpha" -- carp_node_for_vhid 1
t_stdout_is "charlie" "vhid 3 maps back to charlie" -- carp_node_for_vhid 3
t_rc 1 "a vhid no node claims maps to nothing" -- carp_node_for_vhid 9
t_stdout_is "" "and prints nothing while doing it" -- carp_node_for_vhid 9

# --- the advskews ARE the succession map -------------------------------------

t_stdout_is "0" "a node is the owner of its own vhid" -- carp_skew bravo bravo
t_stdout_is "100" "bravo is alpha's heir, so 100 on alpha's vhid" -- \
    carp_skew bravo alpha
t_stdout_is "200" "bravo is charlie's second heir, so 200 on charlie's vhid" -- \
    carp_skew bravo charlie
t_stdout_is "100" "charlie is bravo's heir" -- carp_skew charlie bravo
t_stdout_is "200" "and alpha's second heir" -- carp_skew charlie alpha

# --- participation, in a fixed order -----------------------------------------

t_is "$( carp_participation bravo )" \
    "bravo 2 192.0.2.102/32 0
alpha 1 192.0.2.101/32 100
charlie 3 192.0.2.103/32 200" \
    "bravo takes part in all three vhids, its own first"

t_is "$( carp_participation bravo )" "$( carp_participation bravo )" \
    "and the order is stable between calls, because it decides the alias indices"

# --- the rendering -----------------------------------------------------------

RC=$( carp_render_rc bravo )

t_like "${RC}" '^ifconfig_vtnet0_alias0="inet 192\.0\.2\.102/32 vhid 2 advskew 0 pass notthepassword"' \
    "alias0 is this node's own vhid at advskew 0"
t_like "${RC}" '^ifconfig_vtnet0_alias1="inet 192\.0\.2\.101/32 vhid 1 advskew 100 pass notthepassword"' \
    "alias1 is the vhid of the node it is heir to, at 100"
t_like "${RC}" '^ifconfig_vtnet0_alias2="inet 192\.0\.2\.103/32 vhid 3 advskew 200 pass notthepassword"' \
    "alias2 is the vhid of the node it is second heir to, at 200"
# D-179: the rendering may not assign kld_list -- its documented use is
# appending to rc.conf, rc.conf is shell, and an appended assignment would
# REPLACE the node's module list at the next boot. The module's loading is the
# operator's sysrc += (which the rendering's own comment now prescribes) and
# the check's WARN.
t_unlike "${RC}" '^kld_list=' \
    "the rendering does not assign kld_list -- appended, that would replace the node's list"
t_like "${RC}" 'sysrc kld_list\+="carp"' \
    "and its comment prescribes the append that cannot clobber"
t_like "${RC}" 'CONTIGUOUS FROM 0' \
    "and the rendering says the indices must be contiguous, which rc.conf(5) requires"
t_like "${RC}" 'THE CARP PASSWORD IS IN THE TEXT BELOW' \
    "and that the file it lands in carries a credential"

t_is "$( printf '%s\n' "${RC}" | grep -c '^ifconfig_' )" "3" \
    "three vhids, three alias lines, and no fourth"

# The rendering is what the operator applies, so nothing in the lines it will
# apply may be a placeholder seance forgot to fill in. (The prose above them
# names rc.conf(5)'s own <if> and <n>, which is why this looks only at the
# assignments.)
t_unlike "$( printf '%s\n' "${RC}" | grep -v '^#' )" '<[a-z]+>' \
    "no rendered assignment carries an unsubstituted placeholder"

# --- no password configured --------------------------------------------------

printf '%s\n' "${RING}" | grep -v '^carp_pass=' > "${DIR}/nopass.conf"
conf_load "${DIR}/nopass.conf" || t_diag "nopass.conf failed to load"
NOPASS=$( carp_render_rc bravo )
t_like "${NOPASS}" '^ifconfig_vtnet0_alias0="inet 192\.0\.2\.102/32 vhid 2 advskew 0" ' \
    "with carp_pass unset the pass parameter is omitted, not rendered empty"
t_unlike "${NOPASS}" 'THE CARP PASSWORD IS IN THE TEXT BELOW' \
    "and the warning about the credential is omitted with it"

conf_load "${DIR}/ring.conf" || t_diag "ring.conf failed to reload"

# --- devd --------------------------------------------------------------------

DEVD=$( carp_render_devd bravo )

t_like "${DEVD}" 'match "subsystem"	"1@vtnet0";' \
    "a rule for alpha's vhid, which bravo may inherit"
t_like "${DEVD}" 'match "subsystem"	"3@vtnet0";' \
    "a rule for charlie's vhid, which bravo may inherit as second heir"
t_unlike "${DEVD}" 'match "subsystem"	"2@vtnet0";' \
    "and NO rule for bravo's own vhid: becoming MASTER for oneself is a boot, not a death"

t_is "$( printf '%s\n' "${DEVD}" | grep -c '^notify 0 {' )" "2" \
    "two rules, one per inheritable vhid"
t_like "${DEVD}" 'match "type"		"MASTER";' \
    "each rule matches the MASTER transition, which is the one that means a death"
t_like "${DEVD}" 'match "system"		"CARP";' "under system CARP"
# shellcheck disable=SC2016
#   The single quotes are the point: $subsystem is devd(8)'s own variable and
#   must appear in the rendered file literally, so the pattern asserts exactly
#   that -- an expansion here would assert that it had been expanded.
t_like "${DEVD}" 'action "/usr/local/bin/platform seance promote-event \$subsystem";' \
    "and runs the platform's own verb with devd's \$subsystem, unexpanded"

t_stdout_is "${STUB_VERB} promote-event \$subsystem" \
    "carp_devd_action is that command, and nothing else" -- carp_devd_action

# --- the shapes that would silently not work ---------------------------------

t_stdout_is "vlan0_10" \
    "an interface name is normalised for the variable name, as network.subr does" -- \
    carp_rcvar_if vlan0.10
t_stdout_is "lagg0_5" "a hyphen normalises too" -- carp_rcvar_if lagg0-5
t_stdout_is "vtnet0" "and an ordinary name is left alone" -- carp_rcvar_if vtnet0

t_stdout_is '1@vlan0\.10' \
    "the devd pattern escapes the interface's dots, because devd matches a regex" -- \
    carp_devd_pattern 1 vlan0.10
t_stdout_is '1@vtnet0' "and leaves a name with no metacharacters alone" -- \
    carp_devd_pattern 1 vtnet0

# --- a per-node interface override --------------------------------------------
#
# The shape a pseudo-cluster needs and a mixed fleet needs: one file, and each
# node naming its own interface in its own block.

printf '%s\n' "${RING}" > "${DIR}/perif.conf"
printf 'node_bravo_carp_interface=epair1b\n' >> "${DIR}/perif.conf"
conf_load "${DIR}/perif.conf" || t_diag "perif.conf failed to load"

t_stdout_is "epair1b" "bravo's own block beats the fleet key" -- carp_interface bravo
t_stdout_is "vtnet0" "and changes nothing for the nodes that did not override it" -- \
    carp_interface charlie
t_like "$( carp_render_rc bravo )" '^ifconfig_epair1b_alias0=' \
    "and the rendering follows it, variable name and all"
t_like "$( carp_render_devd bravo )" 'match "subsystem"	"1@epair1b";' \
    "as does the devd pattern, because devd names the interface the event was on"

conf_load "${DIR}/ring.conf" || t_diag "ring.conf failed to reload"

# --- a node that takes no part ------------------------------------------------
#
# N=4 with a ring of three: delta is heir to nobody and nobody's heir, so it has
# nothing to render and says so rather than printing an empty file.

cat > "${DIR}/four.conf" <<'EOF'
carp_interface=vtnet0
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
node_delta_nodename=delta.example.net
node_delta_mgmt=delta-mgmt.example.net
EOF
conf_load "${DIR}/four.conf" || t_diag "four.conf failed to load"

t_rc 1 "a node with no vhid and no inheritance takes part in nothing" -- \
    carp_participation delta
t_rc 1 "so there is nothing to render for it" -- carp_render_rc delta
t_stdout_is "" "and nothing is printed" -- carp_render_rc delta

t_is "$( carp_participation alpha )" \
    "alpha 1 192.0.2.101/32 0
bravo 2 192.0.2.102/32 100" \
    "alpha takes part in two: its own and the one it is heir to"

# --- no CARP at all: an M2 fleet ---------------------------------------------

cat > "${DIR}/nocarp.conf" <<'EOF'
node_alpha_nodename=alpha.example.net
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_bravo_nodename=bravo.example.net
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
EOF
conf_load "${DIR}/nocarp.conf" || t_diag "nocarp.conf failed to load"

t_rc 1 "a fleet with no vhids is not CARP-configured" -- carp_configured
t_rc 1 "and carp_interface has nothing to say" -- carp_interface alpha
t_rc 1 "and rendering refuses rather than printing an empty file" -- \
    carp_render_rc alpha
t_rc 1 "the same for devd" -- carp_render_devd alpha

t_done
