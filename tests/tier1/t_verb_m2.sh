#!/bin/sh
# Tier 1 -- the M2 verbs at the dispatcher's own level.
#
# tests/tier4/t_ladder.sh drives lib/promote.subr IN PROCESS, which is what
# lets it inject a world; the cost is that it never runs bin/seance. This file
# is the other half: it executes the dispatcher, so that a sourcing order that
# is `sh -n` clean but broken at run time, an argument the parser forgets, or a
# usage text that has drifted from the verbs, fails here rather than in a
# reaper session.
#
# Nothing here needs an adapter, a peer or a disk. Everything that does is
# tier 4's or tier 6's.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SEANCE="${T_ROOT}/bin/seance"

# A configuration that validates, so that a usage error can be told apart from
# a configuration error: both exit 2, and the difference is the message.
CONF=$( t_tmpdir )/seance.conf
cat > "${CONF}" <<'EOF'
node_alpha_nodename=alpha
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
EOF

STATE=$( t_tmpdir )/state
RUN=$( t_tmpdir )/run
mkdir -p "${STATE}" "${RUN}"

# seance <args...> -- the dispatcher, with a configuration and no adapter.
#
# SEANCE_ADAPTER points at a path that does not exist on purpose: bin/seance
# sources the adapter only when it is readable (D-66), and the verbs that do
# not need one must still work. `placement` is the one that matters -- it is
# what every peer runs on every other peer over ssh, and a node whose platform
# is not up must still be able to answer it.
seance()
{
    env SEANCE_CONF="${CONF}" \
        SEANCE_STATE_DIR="${STATE}" \
        SEANCE_RUN_DIR="${RUN}" \
        SEANCE_ADAPTER=/nonexistent/no-adapter-here \
        "${SEANCE}" "$@"
}

t_plan 24

# ---------------------------------------------------------------------------
# The verbs exist and are dispatched
# ---------------------------------------------------------------------------

HELP=$( seance help )
for v in promote failback failback-assist gate placement; do
    t_like "${HELP}" "^  ${v}" "seance help documents the ${v} verb"
done

t_rc 2 "an unknown verb is still a usage error" -- seance exorcise

# ---------------------------------------------------------------------------
# placement: the verb a peer runs over ssh, and it needs no adapter
# ---------------------------------------------------------------------------

t_stdout_is "placement: 0 guest(s) hosted away from home" \
    "placement answers with a verdict line and no adapter at all" \
    -- seance placement

t_rc 2 "placement rejects an argument it does not know" -- seance placement --bogus

# A claim, planted the way promote would write it, is printed as a prefixed
# tab-separated record so that a peer can select the data from the verdict.
printf 'web01\tbravo\n' > "${STATE}/placement"
t_like "$( seance placement )" "^placement	web01	bravo\$" \
    "a claim is printed as one prefixed, tab-separated record"
t_like "$( seance placement )" '^placement: 1 guest\(s\) hosted away from home$' \
    "and the verdict line counts it"
: > "${STATE}/placement"

# ---------------------------------------------------------------------------
# promote: argument discipline
# ---------------------------------------------------------------------------

t_rc 2 "promote with no node named is a usage error" -- seance promote

PROBES=$( t_tmpdir )/probes.err
seance promote alpha --force=probes 2> "${PROBES}" > /dev/null
t_is "$?" "2" "promote --force=probes is a usage error"
t_like "$( cat "${PROBES}" )" 'never fenced by force' \
    "and it says why, rather than only refusing"

t_rc 2 "promote --force naming a rung that does not exist is a usage error" \
    -- seance promote alpha --force=nosuchrung
t_rc 2 "promote naming two nodes is a usage error" -- seance promote alpha bravo
t_rc 2 "promote rejects an option it does not know" -- seance promote alpha --wat

# ---------------------------------------------------------------------------
# failback and failback-assist: argument discipline
# ---------------------------------------------------------------------------

t_rc 2 "failback with no guest named is a usage error" -- seance failback
t_rc 2 "failback naming two guests is a usage error" -- seance failback web01 db01
t_rc 2 "failback rejects an option it does not know" -- seance failback web01 --wat

t_rc 2 "failback-assist with no operation is a usage error" \
    -- seance failback-assist web01
t_rc 2 "failback-assist with too many arguments is a usage error" \
    -- seance failback-assist web01 stop extra

# ---------------------------------------------------------------------------
# gate: argument discipline
# ---------------------------------------------------------------------------

t_rc 2 "gate rejects an argument it does not know" -- seance gate --bogus
t_rc 2 "gate --release with no guest is a usage error" -- seance gate --release

# ---------------------------------------------------------------------------
# The config is still the gate on everything that acts
# ---------------------------------------------------------------------------

t_rc 2 "promote refuses to run without a configuration file" \
    -- env SEANCE_STATE_DIR="${STATE}" SEANCE_RUN_DIR="${RUN}" \
    SEANCE_ADAPTER=/nonexistent/no-adapter-here "${SEANCE}" promote alpha

t_done
