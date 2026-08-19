#!/bin/sh
# Tier 1 -- what a fleet's configuration says about the AUTOMATIC path.
#
# `--auto` acts only when two switches agree (D-118): the fleet key `auto` and
# this node's own `auto_promote`. Between them and the CARP model sits a set of
# arrangements a file can express and a fleet cannot honour, and every one of
# them looks like a working configuration until the first death:
#
#   * a node armed to succeed a node it may never inherit -- CARP hands that
#     vhid somewhere else;
#   * a node armed to succeed a node whose death emits no CARP transition at
#     all (the corpse has no vhid);
#   * a node armed to succeed somebody and carrying no interface to hear it on.
#     The alias for the corpse's vhid has nowhere to go, so nothing on this
#     node will ever become MASTER for it. That is D-116's failure exactly --
#     everything reads correct until a death nobody detects -- and it is
#     visible in the file, which is byte-identical across the mesh (handoff
#     §2.2), so the validator every operator already runs can see it.
#
# The positive cases are here for the same reason the negative ones are: a
# validator that refuses a legal fleet is as expensive as one that passes an
# illegal one, and the arrangement seance actually recommends -- one heir armed
# for one node -- must pass.
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

# A three-node ring with CARP on every node, `auto` on, and bravo armed for
# alpha -- the arrangement design §12 describes, and the one the fixtures below
# each break in exactly one way.
GOOD='carp_interface=vtnet0
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
node_charlie_vhid_ip=192.0.2.103/32'

# build <replacements-on-stdin>  -- GOOD with lines removed or added.
#
# A line given as "-<key>" removes that key; anything else is appended, which
# (conf_load refusing duplicates, D-32) means the key must have been removed
# first. The fixture is therefore explicit about what it changed.
build()
{
    local _f _l _tmp

    N=$(( N + 1 ))
    _f="${DIR}/case${N}.conf"
    _tmp="${DIR}/case${N}.in"

    cat > "${_tmp}"
    printf '%s\n' "${GOOD}" > "${_f}"

    while IFS= read -r _l || [ -n "${_l}" ]; do
        case "${_l}" in
            '') continue ;;
            -*)
                grep -v "^${_l#-}=" "${_f}" > "${_f}.new" && mv "${_f}.new" "${_f}"
                ;;
            *) printf '%s\n' "${_l}" >> "${_f}" ;;
        esac
    done < "${_tmp}"

    printf '%s\n' "${_f}"
}

# refuses <name> <expected problem> -- config on stdin
refuses()
{
    local _name _want _f _out

    _name=$1
    _want=$2
    _f=$( build )

    if ! conf_load "${_f}"; then
        t_not_ok "${_name}"
        t_diag "the fixture did not parse, so the check was never reached"
        return 0
    fi

    if _out=$( conf_check ); then
        t_not_ok "${_name}"
        t_diag "conf_check passed a configuration it should have rejected:"
        t_diag "${_out}"
        return 0
    fi

    t_like "${_out}" "${_want}" "${_name}"
}

# accepts <name>  -- config on stdin
accepts()
{
    local _name _f _out

    _name=$1
    _f=$( build )

    if ! conf_load "${_f}"; then
        t_not_ok "${_name}"
        t_diag "the fixture did not parse"
        return 0
    fi

    if ! _out=$( conf_check ); then
        t_not_ok "${_name}"
        t_diag "conf_check refused a legal configuration:"
        t_diag "${_out}"
        return 0
    fi

    t_ok "${_name}"
}

t_plan 16

# --- the arrangement the design recommends ---------------------------------

accepts "one heir armed for one node, on a fleet with CARP everywhere, passes" \
    < /dev/null

accepts "and arming the node one is SECOND heir to is legal: it may inherit it" <<'EOF'
node_charlie_auto_promote=alpha
EOF

accepts "two corpses on one arming list are both checked and both legal" <<'EOF'
-node_bravo_auto_promote
node_bravo_auto_promote=alpha charlie
EOF

# --- arming that CARP can never honour --------------------------------------

# A ring of three makes every node heir or heir2 of every other, so the fleet
# that can express this at all has four.
refuses "arming a node this one may not inherit is refused" \
    'node bravo: auto_promote names delta, but bravo is neither node_delta_heir nor node_delta_heir2' <<'EOF'
node_delta_nodename=delta.example.net
node_delta_mgmt=delta-mgmt.example.net
node_delta_heir=charlie
node_delta_heir2=alpha
node_delta_vhid=4
node_delta_vhid_ip=192.0.2.104/32
-node_bravo_auto_promote
node_bravo_auto_promote=delta
EOF

refuses "arming oneself is refused" \
    'node bravo: auto_promote names the node itself' <<'EOF'
-node_bravo_auto_promote
node_bravo_auto_promote=bravo
EOF

refuses "arming a node that is not in the configuration is refused" \
    'auto_promote names "delta", which is not a configured node' <<'EOF'
-node_bravo_auto_promote
node_bravo_auto_promote=delta
EOF

refuses "arming a node whose death emits no CARP transition is refused" \
    'auto_promote names alpha, which has no node_alpha_vhid' <<'EOF'
-node_alpha_vhid
-node_alpha_vhid_ip
EOF

# THE ONE THIS FILE WAS WRITTEN FOR. bravo is armed, alpha has a vhid, and
# bravo has no interface to carry alpha's alias on -- so no transition can ever
# make bravo MASTER for it. Every other check passes; the automation is on, and
# it is deaf.
refuses "arming with no interface to hear the transition on is refused" \
    'node bravo: auto_promote names alpha, and bravo resolves no carp_interface' <<'EOF'
-carp_interface
-node_bravo_vhid
-node_bravo_vhid_ip
node_alpha_carp_interface=vtnet0
node_charlie_carp_interface=vtnet0
EOF

accepts "and a per-node carp_interface satisfies it with no fleet key at all" <<'EOF'
-carp_interface
node_alpha_carp_interface=vtnet0
node_bravo_carp_interface=epair1b
node_charlie_carp_interface=vtnet0
EOF

# --- the two switches are independent ---------------------------------------

accepts "the fleet key on with nothing armed anywhere is legal: two switches, and this is one of them" <<'EOF'
-node_bravo_auto_promote
EOF

accepts "and an arming list on a fleet whose auto key is off is legal too" <<'EOF'
-auto
auto=0
EOF

# ... but a disarmed fleet's arming lists are still validated, because the key
# an operator turns off in a hurry is the one they turn back on in a hurry.
refuses "a fleet with auto=0 still refuses an arming CARP could not honour" \
    'node bravo: auto_promote names delta, but bravo is neither' <<'EOF'
node_delta_nodename=delta.example.net
node_delta_mgmt=delta-mgmt.example.net
node_delta_heir=charlie
node_delta_heir2=alpha
node_delta_vhid=4
node_delta_vhid_ip=192.0.2.104/32
-auto
auto=0
-node_bravo_auto_promote
node_bravo_auto_promote=delta
EOF

refuses "the fleet key is 0 or 1 and nothing else" \
    'auto' <<'EOF'
-auto
auto=yes
EOF

refuses "and 2 is not 'more automatic'" \
    'auto' <<'EOF'
-auto
auto=2
EOF

# --- what conf_effective hands the ladder -----------------------------------

_f=$( build < /dev/null )
conf_load "${_f}" > /dev/null 2>&1
t_is "$( conf_effective auto )" "1" \
    "conf_effective auto is what rung 0 reads, and it reads 1 here"

_f=$( build <<'EOF'
-auto
EOF
)
conf_load "${_f}" > /dev/null 2>&1
t_is "$( conf_effective auto )" "0" \
    "and a fleet that never mentions auto is disarmed by default, not armed"

t_done
