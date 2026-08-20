#!/bin/sh
# Tier 1 -- the M3 verbs and flags at the dispatcher's own level.
#
# tests/tier4/t_ladder.sh drives lib/promote.subr IN PROCESS and
# tests/tier1/t_carp.sh drives lib/carp.subr the same way; neither of them runs
# bin/seance. This file is the other half, for the same reason t_verb_m2.sh
# exists: a sourcing order that is `sh -n` clean and broken at run time, a flag
# the parser forgets, or a usage text that has drifted from the verbs, has to
# fail here rather than in a reaper session.
#
# THE ASSERTION THIS FILE EXISTS FOR is that `--force` and `--auto` are refused
# together BEFORE anything else happens -- before a configuration is loaded,
# before an adapter is started, and long before a fence driver is run. A
# refusal that arrived four rungs later would still be a refusal, but the
# machine would have fenced a node on the way to it.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SEANCE="${T_ROOT}/bin/seance"

CONF=$( t_tmpdir )/seance.conf
cat > "${CONF}" <<'EOF'
carp_interface=vtnet0
carp_pass=notthepassword
auto=1

node_alpha_nodename=alpha
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_alpha_vhid=1
node_alpha_vhid_ip=192.0.2.101/32

node_bravo_nodename=bravo
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
node_bravo_vhid=2
node_bravo_vhid_ip=192.0.2.102/32
node_bravo_auto_promote=alpha
EOF

STATE=$( t_tmpdir )/state
RUN=$( t_tmpdir )/run
mkdir -p "${STATE}" "${RUN}"

# seance <args...>
#
# The dispatcher with a configuration and NO adapter (D-66: the adapter is
# sourced only when it is readable). Everything asserted below is answered
# before an adapter would be needed, which is the point: a usage error must not
# require a platform to be diagnosed.
seance()
{
    env SEANCE_CONF="${CONF}" \
        SEANCE_STATE_DIR="${STATE}" \
        SEANCE_RUN_DIR="${RUN}" \
        SEANCE_ADAPTER=/nonexistent/no-adapter-here \
        "${SEANCE}" "$@"
}

t_plan 21

# ---------------------------------------------------------------------------
# The verbs and flags are documented where an operator will look
# ---------------------------------------------------------------------------

HELP=$( seance help )
t_like "${HELP}" '^  promote-event <vhid>@<ifname>' \
    "seance help documents the promote-event verb"
t_like "${HELP}" '^  promote <deadnode> \[--auto\]' \
    "and that promote takes --auto"
t_like "${HELP}" '^  verify \[--render cron\|carp\|devd\]' \
    "and that verify renders all three subjects"

# ---------------------------------------------------------------------------
# --auto and --force are not expressible together
# ---------------------------------------------------------------------------

for f in --force --force=fence --force=quorum,lineage; do
    OUT=$( seance promote alpha --auto "${f}" 2>&1 )
    RC=$?
    if [ "${RC}" -ne 2 ]; then
        t_not_ok "promote alpha --auto ${f} is a usage error"
        t_diag "exit ${RC}: ${OUT}"
    else
        t_like "${OUT}" '--force may not be combined with --auto' \
            "promote alpha --auto ${f} is a usage error, and says which two flags"
    fi
done

# The order the operator typed them in is not the point, so it must not change
# the answer.
t_rc 2 "and the flags in the other order are refused identically" -- \
    seance promote alpha --force --auto

# The refusal is a USAGE error and reaches nothing: with no adapter present, a
# promote that got as far as needing one would exit 2 with a different message,
# so the message is what tells the two apart.
t_unlike "$( seance promote alpha --auto --force 2>&1 )" 'no adapter at' \
    "the refusal happens before the adapter is asked for"

# Each flag alone is accepted by the parser -- it is the pair that is refused,
# not either of them. Without an adapter both then stop for that reason, which
# is the message being matched.
t_like "$( seance promote alpha --auto 2>&1 )" 'no adapter at' \
    "--auto alone parses, and stops only for the missing adapter"
t_like "$( seance promote alpha --force=fence 2>&1 )" 'no adapter at' \
    "--force alone parses too"

# ---------------------------------------------------------------------------
# promote-event: the devd target's own argument contract
# ---------------------------------------------------------------------------

t_rc 2 "promote-event with no argument is a usage error" -- seance promote-event
t_rc 2 "promote-event with two arguments is a usage error" -- \
    seance promote-event 1@vtnet0 extra
t_like "$( seance promote-event 1@vtnet0 extra 2>&1 )" \
    'usage: seance promote-event <vhid>@<ifname>' \
    "and the usage names the shape devd(8) supplies"

# ---------------------------------------------------------------------------
# verify --render
# ---------------------------------------------------------------------------

# --render cron needs the adapter TOO, and that is an M5 change made because
# the old contract was what let it render a command that cannot run: the line
# names what cron will execute with an environment of its own, and only the
# platform can say what runs a seance verb there (D-117). Rendered from
# bin/seance the line exited 2 with "no config file" every time cron fired it,
# on every freshly installed node, while `verify` called the line correct.
t_like "$( seance verify --render cron 2>&1 )" 'no adapter at' \
    "verify --render cron needs the adapter: the line names the platform's verb"
t_rc 2 "verify --render with an unknown subject is a usage error" -- \
    seance verify --render exorcism
t_like "$( seance verify --render exorcism 2>&1 )" 'known: cron carp devd' \
    "and the diagnostic names every subject there is"
t_like "$( seance verify --render 2>&1 )" 'needs a subject \(cron carp devd\)' \
    "as does the one for --render with nothing after it"

# carp and devd need this node's identity, which is the adapter's fact, so on a
# machine with no adapter they stop for that -- and say so, rather than
# rendering a file for a node they had to guess the name of.
t_like "$( seance verify --render carp 2>&1 )" 'no adapter at' \
    "verify --render carp needs the adapter, because it renders for THIS node"
t_like "$( seance verify --render devd 2>&1 )" 'no adapter at' \
    "and so does verify --render devd"

# ---------------------------------------------------------------------------
# The dispatcher still answers everything it used to
# ---------------------------------------------------------------------------

t_rc 2 "an unknown verb is still a usage error" -- seance exorcise
t_stdout_is "placement: 0 guest(s) hosted away from home" \
    "and placement still answers with no adapter at all" -- seance placement

t_done
