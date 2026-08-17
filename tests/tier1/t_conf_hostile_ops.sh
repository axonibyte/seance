#!/bin/sh
# Tier 1 -- configurations that PASS every syntax rule and are hostile anyway.
#
# t_conf_parse.sh is about grammar and t_conf_hostile.sh is about bytes. This
# file is about the third kind of bad configuration, the one that costs the
# most: the file that loads, validates, and describes a fleet that cannot do
# what its operator believes it will. `seance config --check` is what stands
# between a site and that file -- every verb runs it before it does anything
# (bin/seance:154-157) -- so a hostility it does not name is one that is found
# during an outage.
#
# The two that were found here, and are now named:
#
#   * TWO NODE KEYS WITH ONE MANAGEMENT ADDRESS. The quorum rule is
#     `1 + reachable_others > N/2` and "reachable" is counted by probing each
#     configured node's mgmt address (promote_reachable_peers). Two keys
#     pointing at one host make one living machine answer twice: N goes up by
#     one and so does the count of the living, and a four-node fleet with one
#     surviving peer computes a majority it does not have. That is the split
#     brain this product exists to prevent, arriving through a copy-paste in a
#     config file with a green `--check`.
#   * A GUEST REPLICATED TO ITS OWN HOME. A per-guest heir override replaces
#     the node's succession entirely (D-29), and nothing in the file says where
#     a guest lives -- so `guest_web01_heir=alpha` is valid, and on alpha it
#     used to mean "replicate web01 to alpha". A second copy of a live guest,
#     on the same node, in the standby tree, where the estate discovery of a
#     promotion looks (D-44 item 3).
#
# And the ones that CANNOT be caught here, asserted as passing so that the
# limit is written down rather than assumed: a fence driver named without a
# target (the ladder aborts on it -- tests/tier4/ladder.tsv row
# `fence-target-missing`), and an N=2 fleet, which is legal, common, and
# freezes on the death of its peer by design.
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
# shellcheck source=../../lib/zfs.subr
. "${T_ROOT}/lib/zfs.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/lineage.subr
. "${T_ROOT}/lib/lineage.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/repl.subr
. "${T_ROOT}/lib/repl.subr"

DIR=$( t_tmpdir )

# check <name>  -- write the config on stdin, load it, print conf_check's
# output. A load that fails prints its own errors and "LOAD FAILED", so that a
# file this suite believes is loadable and is not cannot pass silently.
#
# It is called inside $( ), so the configuration it loaded belongs to a
# subshell and is gone by the time the assertion is read. Anything that has to
# ask the LOADED configuration a question calls `load` afterwards, in this
# shell -- which is also why `load` prints nothing: a silent second load is not
# evidence of anything, and the assertion that follows it is.
check()
{
    cat > "${DIR}/$1.conf"
    if ! conf_load "${DIR}/$1.conf" 2>&1; then
        printf 'LOAD FAILED\n'
        return 2
    fi
    conf_check
}

# verdict <check-output>  -- the LAST line of it, which is conf_check's
# verdict. Compared instead of the whole output because a check that grows a
# warning line above its verdict has not stopped passing -- and because the
# verdict line being last is the rule this project holds every verb to.
verdict()
{
    printf '%s\n' "$1" | awk 'NF > 0 { line = $0 } END { print line }'
}

# load <name>  -- the same file, into THIS shell.
load()
{
    conf_load "${DIR}/$1.conf" > /dev/null 2>&1 ||
        t_diag "load: ${DIR}/$1.conf did not load in the test's own shell"
}

t_plan 17

# ---------------------------------------------------------------------------
# Two node keys, one management address
# ---------------------------------------------------------------------------

OUT=$( check dupmgmt <<'EOF'
node_alpha_nodename=alpha
node_alpha_mgmt=10.0.0.1
node_alpha_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=10.0.0.2
node_bravo_heir=charlie

node_charlie_nodename=charlie
node_charlie_mgmt=10.0.0.2
node_charlie_heir=alpha
EOF
)

t_unlike "${OUT}" 'LOAD FAILED' \
    "the file loads: this is a check fault, not a parse fault"
t_like "${OUT}" '^problem: node charlie: mgmt "10\.0\.0\.2" is claimed by more than one node' \
    "two node keys with one mgmt address are named, and the second one is named"
t_like "${OUT}" '^FAIL: ' "and the check fails, so no verb will run on it"

# The consequence, spelled out where it bites: the quorum arithmetic counts
# node KEYS, so one living host answering twice is a majority that is not
# there. N=4, one real peer alive plus its double: pol_quorum says act.
t_is "$( pol_quorum 4 2 )" "act" \
    "N=4 with two reachable others acts -- which is what the doubled address would have produced"
t_is "$( pol_quorum 4 1 )" "freeze" \
    "and N=4 with the ONE peer that is really there freezes, which is the answer that was being lost"

# Three keys on one address: every duplicate is named, not just the first.
OUT=$( check dupmgmt3 <<'EOF'
node_alpha_nodename=alpha
node_alpha_mgmt=10.0.0.9
node_alpha_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=10.0.0.9
node_bravo_heir=charlie

node_charlie_nodename=charlie
node_charlie_mgmt=10.0.0.9
node_charlie_heir=alpha
EOF
)
t_is "$( printf '%s\n' "${OUT}" | grep -c 'claimed by more than one node' )" "2" \
    "three keys on one address produce a problem for each key after the first"

# And the fleet that is merely similar still passes: the check must not fire on
# addresses that share a prefix, which is what a substring test would have done.
OUT=$( check nodup <<'EOF'
node_alpha_nodename=alpha
node_alpha_mgmt=10.0.0.1
node_alpha_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=10.0.0.10
node_bravo_heir=alpha
EOF
)
t_is "$( verdict "${OUT}" )" "PASS" \
    "10.0.0.1 and 10.0.0.10 are different addresses, and a prefix is not a duplicate"

# ---------------------------------------------------------------------------
# A guest whose succession names the node it lives on
# ---------------------------------------------------------------------------

OUT=$( check selfrepl <<'EOF'
node_alpha_nodename=alpha
node_alpha_mgmt=10.0.0.1
node_alpha_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=10.0.0.2
node_bravo_heir=alpha

guest_web01_heir=alpha
guest_web01_heir2=bravo
EOF
)

# It passes, and it has to: nothing in the file says where web01 lives, so
# "alpha is web01's heir" is only wrong on alpha. The check cannot know; the
# tick can, and that is where it is refused.
t_is "$( verdict "${OUT}" )" "PASS" \
    "a per-guest heir naming a node passes the check: the file does not say where the guest lives"

load selfrepl
t_is "$( repl_peers web01 alpha | tr '\n' ' ' )" "bravo " \
    "but a guest is never replicated to its own home: alpha is dropped from web01's succession on alpha"
t_is "$( repl_peers web01 bravo | tr '\n' ' ' )" "alpha " \
    "and the same override read on bravo keeps alpha and drops bravo: whichever node asks, its own key is the one that goes"

# The whole override being the home node leaves nothing, which repl reports as
# "nowhere to replicate to" rather than as a tick that quietly did nothing.
OUT=$( check selfonly <<'EOF'
node_alpha_nodename=alpha
node_alpha_mgmt=10.0.0.1
node_alpha_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=10.0.0.2
node_bravo_heir=alpha

guest_web01_heir=alpha
EOF
)
t_is "$( verdict "${OUT}" )" "PASS" "an override naming only the home node still passes the check"
load selfonly
t_rc 1 "and repl_peers has nothing left to answer with, which the tick reports loudly" \
    -- repl_peers web01 alpha

# The node's own succession, which the check CAN see, is still caught there --
# this is the same hostility one level up, and it must not have been traded for
# the new one.
OUT=$( check selfheir <<'EOF'
node_alpha_nodename=alpha
node_alpha_mgmt=10.0.0.1
node_alpha_heir=alpha

node_bravo_nodename=bravo
node_bravo_mgmt=10.0.0.2
node_bravo_heir=alpha
EOF
)
t_like "${OUT}" '^problem: node alpha: heir is the node itself' \
    "a node that is its own heir is still caught by the check, where it can be"

# ---------------------------------------------------------------------------
# The hostilities that CANNOT be caught here, written down as passing
# ---------------------------------------------------------------------------

# A driver with nothing to name to it. conf_check requires a driver for every
# target (lib/conf.subr:715-717) and deliberately not the reverse, because a
# driver key alone is how a site stages a rollout. The ladder is where it stops
# being harmless: tests/tier4/ladder.tsv row `fence-target-missing`.
OUT=$( check drvnotarget <<'EOF'
node_alpha_nodename=alpha
node_alpha_mgmt=10.0.0.1
node_alpha_heir=bravo
node_alpha_fence_driver=mock

node_bravo_nodename=bravo
node_bravo_mgmt=10.0.0.2
node_bravo_heir=alpha
EOF
)
t_is "$( verdict "${OUT}" )" "PASS" \
    "a fence_driver with no fence_target passes the check; rung 4 is where it aborts"

# The reverse is caught, and stays caught.
OUT=$( check targetnodrv <<'EOF'
node_alpha_nodename=alpha
node_alpha_mgmt=10.0.0.1
node_alpha_heir=bravo
node_alpha_fence_target=alpha

node_bravo_nodename=bravo
node_bravo_mgmt=10.0.0.2
node_bravo_heir=alpha
EOF
)
t_like "${OUT}" '^problem: node alpha: fence_target is set without a fence_driver' \
    "and a target with no driver is still a problem: that one looks armed and is not"

# An N=2 fleet: legal, common, and unable to form a quorum the moment its peer
# dies. seance says so by freezing rather than by refusing the configuration --
# the design's own answer for even N (design §3), and the reason `--force=quorum`
# exists at all.
OUT=$( check n2 <<'EOF'
node_alpha_nodename=alpha
node_alpha_mgmt=10.0.0.1
node_alpha_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=10.0.0.2
node_bravo_heir=alpha
EOF
)
t_is "$( verdict "${OUT}" )" "PASS" "an N=2 fleet is a legal fleet"
t_is "$( pol_quorum 2 0 )" "freeze" \
    "and it freezes the moment its only peer is the corpse -- always, v1 has no witness"

t_done
