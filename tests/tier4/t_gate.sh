#!/bin/sh
# Tier 4 -- the resurrection gate and the placement records (design §8, D-21).
#
# The gate is the half of the split-brain contract that runs when a node comes
# BACK, and its most important behaviour is the one nobody exercises by
# accident: a node that reaches no peer at all withholds its WHOLE estate. That
# is asserted here, on a workstation, rather than only in the pseudo-cluster --
# because it is the assertion that would otherwise be tested once per reaper
# session and never during an edit.
#
# HOW THE HOLD IS COUNTED. The mock adapter has no database: adapter_guest_hold
# validates its argument and succeeds. So what is asserted is the INVOCATION,
# from SEANCE_MOCK_LOG -- counting the resource rather than the responses,
# which is the same rule the concurrency stage follows.
#
# The mesh is a shell script on PATH, scripted by its own environment, for the
# reason given at length in tests/tier4/t_ladder.sh: seance must not carry a
# code path that only the tests take.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SEANCE_ROOT=${T_ROOT}
export SEANCE_ROOT

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
# shellcheck source=../../lib/transport.subr
. "${T_ROOT}/lib/transport.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/notify.subr
. "${T_ROOT}/lib/notify.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/zfs.subr
. "${T_ROOT}/lib/zfs.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/repl.subr
. "${T_ROOT}/lib/repl.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/status.subr
. "${T_ROOT}/lib/status.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/gate.subr
. "${T_ROOT}/lib/gate.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../mock-adapter.subr
. "${T_ROOT}/tests/mock-adapter.subr"

TAB=$( printf '\t.' )
TAB=${TAB%.}

SEANCE_TMP_REGISTRY=$( t_tmpdir )/registry
: > "${SEANCE_TMP_REGISTRY}"
export SEANCE_TMP_REGISTRY
t_at_exit 'seance_tmp_cleanup'

NOTIFY_TIMEOUT=1

# --- the mesh ---------------------------------------------------------------

SHIM=$( t_tmpdir )/bin
mkdir -p "${SHIM}"

cat > "${SHIM}/ssh" <<'EOF'
#!/bin/sh
set -u
# The target is the argument just before the command, which is the shape every
# seance_ssh call has. Scanning for "*@*" instead would find the '@' inside a
# snapshot name in the command itself.
prev=""
cur=""
for a in "$@"; do
    prev=${cur}
    cur=$a
done
addr=${prev#*@}
cmd=${cur}
case " ${WORLD_SSH_ALIVE:-} " in
    *" ${addr} "*) ;;
    *) echo "ssh: connect to host ${addr}: Connection refused" >&2; exit 255 ;;
esac
case "${cmd}" in
    "exit 0") exit 0 ;;
    "seance placement")
        # A peer whose seance cannot answer. It is UP -- this shim is running,
        # the ssh probe above succeeded -- and the placement query fails or
        # comes back without a verdict line. That is a live node with a broken
        # or half-installed seance, and it is indistinguishable from a healthy
        # one until the question is actually asked.
        case " ${WORLD_SSH_MUTE:-} " in
            *" ${addr} "*)
                echo "seance: not found" >&2
                exit 127
                ;;
        esac
        case " ${WORLD_SSH_PARTIAL:-} " in
            *" ${addr} "*)
                [ -r "${WORLD_DIR}/claims.${addr}" ] && cat "${WORLD_DIR}/claims.${addr}"
                exit 0
                ;;
        esac
        [ -r "${WORLD_DIR}/claims.${addr}" ] && cat "${WORLD_DIR}/claims.${addr}"
        echo "placement: answered"
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF

cat > "${SHIM}/logger" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${WORLD_DIR}/logger.log"
exit 0
EOF

chmod 0755 "${SHIM}/ssh" "${SHIM}/logger"
PATH="${SHIM}:${PATH}"
export PATH

# --- one configuration, three nodes -----------------------------------------

CONF=$( t_tmpdir )/seance.conf
cat > "${CONF}" <<'EOF'
node_alpha_nodename=alpha
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_alpha_heir2=charlie

node_bravo_nodename=bravo
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=charlie
node_bravo_heir2=alpha

node_charlie_nodename=charlie
node_charlie_mgmt=charlie-mgmt.example.net
node_charlie_heir=alpha
node_charlie_heir2=bravo
EOF

conf_load "${CONF}" || { echo "the fixture configuration did not load" >&2; exit 2; }

SEANCE_MOCK_NODE=alpha
SEANCE_MOCK_WORKDIR=$( t_tmpdir )/workdir
export SEANCE_MOCK_NODE SEANCE_MOCK_WORKDIR

# world <alive-addresses> <claiming-peer|-> <claimed-guest|->
#
# A fresh state directory per scenario, so that a hold in one is not a hold in
# the next.
world()
{
    WORLD_DIR=$( t_tmpdir )
    export WORLD_DIR

    SEANCE_STATE_DIR="${WORLD_DIR}/state"
    SEANCE_RUN_DIR="${WORLD_DIR}/run"
    export SEANCE_STATE_DIR SEANCE_RUN_DIR
    mkdir -p "${SEANCE_STATE_DIR}" "${SEANCE_RUN_DIR}"

    SEANCE_MOCK_LOG="${WORLD_DIR}/mock.log"
    export SEANCE_MOCK_LOG
    : > "${SEANCE_MOCK_LOG}"

    WORLD_SSH_ALIVE=$1
    WORLD_SSH_MUTE=""
    WORLD_SSH_PARTIAL=""
    export WORLD_SSH_ALIVE WORLD_SSH_MUTE WORLD_SSH_PARTIAL

    if [ "${2}" != "-" ]; then
        printf 'placement\t%s\talpha\n' "$3" \
            > "${WORLD_DIR}/claims.${2}-mgmt.example.net"
    fi
}

GATE_OUT=""
GATE_RC=0

gate()
{
    GATE_OUT="${WORLD_DIR}/gate.out"
    gate_run "$1" > "${GATE_OUT}" 2>&1
    GATE_RC=$?
}

holds()
{
    awk '$1 == "adapter_guest_hold" { print $2 }' "${SEANCE_MOCK_LOG}" |
        LC_ALL=C sort | tr '\n' ' '
}

t_plan 41

# ---------------------------------------------------------------------------
# The placement file
# ---------------------------------------------------------------------------

world "charlie-mgmt.example.net bravo-mgmt.example.net" - -

t_is "$( placement_local )" "" "a node hosting nothing away from home has an empty placement"
t_rc 1 "and it claims no particular guest either" -- placement_home web01

placement_set web01 charlie
t_is "$( placement_local )" "web01	charlie" "a claim is one record, guest then home"
t_is "$( placement_home web01 )" "charlie" "and it can be read back by guest"

placement_set web01 delta
t_is "$( placement_local )" "web01	delta" \
    "claiming a guest twice replaces the claim rather than duplicating it"

placement_set db01 charlie
t_is "$( placement_local | LC_ALL=C sort | tr '\n' ' ' )" "db01	charlie web01	delta " \
    "two guests, two records"

placement_clear web01
t_is "$( placement_local )" "db01	charlie" "clearing one leaves the other"

t_rc 0 "clearing a guest that was never claimed is not an error" \
    -- placement_clear nosuchguest

# placement_report is the verb's output: records the peers parse, then a
# verdict line they must not parse.
t_like "$( placement_report 0 )" "^placement	db01	charlie$" \
    "seance placement prints a prefixed, tab-separated record per claim"
t_like "$( placement_report 0 )" '^placement: 1 guest\(s\) hosted away from home$' \
    "and ends in one verdict line"

# ---------------------------------------------------------------------------
# The gate, with peers answering
# ---------------------------------------------------------------------------

world "charlie-mgmt.example.net bravo-mgmt.example.net" - -
gate act
t_is "${GATE_RC}" "0" "nothing is withheld when the peers answer and none claims anything"
t_is "$( holds )" "" "and nothing was held"
t_like "$( cat "${GATE_OUT}" )" '2 peer\(s\) answered' \
    "the verdict line says how many peers answered"

# ---------------------------------------------------------------------------
# A peer claims one guest
# ---------------------------------------------------------------------------

world "charlie-mgmt.example.net bravo-mgmt.example.net" bravo web01
gate act
t_is "${GATE_RC}" "1" "a claimed guest makes the gate exit non-zero"
t_is "$( holds )" "web01 " "exactly the claimed guest is withheld, and no other"
t_like "$( cat "${GATE_OUT}" )" '^gate: HELD web01 -- bravo claims it$' \
    "and the line names the guest and the peer that claims it"
t_like "$( cat "${GATE_OUT}" )" '^  undo: seance gate --release web01' \
    "the hold prints its undo"

# --check must decide the same thing and do none of it.
world "charlie-mgmt.example.net bravo-mgmt.example.net" bravo web01
gate check
t_like "$( cat "${GATE_OUT}" )" '^gate: WOULD HOLD web01 -- bravo claims it$' \
    "--check reports the same decision"
t_is "$( holds )" "" "and --check holds nothing at all"

# ---------------------------------------------------------------------------
# THE FAIL-SAFE: not one peer answered
# ---------------------------------------------------------------------------

world "" - -
gate act
t_is "${GATE_RC}" "1" "a node that reaches nobody does not exit 0"
t_is "$( holds )" "arc01 db01 web01 " \
    "a node that reaches NO peer withholds its WHOLE estate, not just what it was asked about"
t_like "$( cat "${GATE_OUT}" )" 'NOT ONE PEER ANSWERED' \
    "and says so in capitals"
t_isnt "$( cat "${WORLD_DIR}/logger.log" 2>/dev/null )" "" \
    "the fail-safe notifies"

# A guest this node hosts for somebody ELSE is not its own to gate: it is
# already displaced, and withholding it would take down a guest that is
# working.
world "" - -
placement_set web01 bravo
gate act
t_is "$( holds )" "arc01 db01 " \
    "a guest this node hosts away from home is not part of the estate the gate withholds"

# ---------------------------------------------------------------------------
# A LIVING PEER THAT CANNOT SAY WHAT IT HOLDS
#
# The gap this closes: `seance_ssh_probe` succeeding is not the peer answering
# the question. A node that is up with a broken or half-installed seance used
# to contribute no claim records and be counted as reached -- so its guests
# read as unclaimed, the gate released them, and they came up in two places.
# An unanswered living peer is not evidence of no claim (design §5).
# ---------------------------------------------------------------------------

world "charlie-mgmt.example.net bravo-mgmt.example.net" bravo web01
WORLD_SSH_MUTE="bravo-mgmt.example.net"
export WORLD_SSH_MUTE
gate act

t_is "${GATE_RC}" "1" "a peer that answers ssh but not the placement query does not exit 0"
t_is "$( holds )" "arc01 db01 web01 " \
    "the WHOLE estate is withheld: a peer whose claims are unknown is not a peer with none"
t_like "$( cat "${GATE_OUT}" )" '^gate: HELD web01 -- living peer\(s\) bravo could not report their placement$' \
    "and every held guest names the peer that could not answer"
t_like "$( cat "${GATE_OUT}" )" 'LIVING PEER\(S\) bravo COULD NOT REPORT THEIR PLACEMENT' \
    "the verdict line shouts it, because that is the line somebody skims"
t_isnt "$( cat "${WORLD_DIR}/logger.log" 2>/dev/null )" "" \
    "and it notifies, like the other half of the fail-safe"

# An answer with no verdict line is a half-written answer, and the records it
# did not get to are exactly the ones that would read as "no claim".
world "charlie-mgmt.example.net bravo-mgmt.example.net" bravo web01
WORLD_SSH_PARTIAL="bravo-mgmt.example.net"
export WORLD_SSH_PARTIAL
gate act
t_is "$( holds )" "arc01 db01 web01 " \
    "a peer that answers without its verdict line is treated the same way"

# --check must reach the same conclusion and change nothing.
world "charlie-mgmt.example.net bravo-mgmt.example.net" bravo web01
WORLD_SSH_MUTE="bravo-mgmt.example.net"
export WORLD_SSH_MUTE
gate check
t_like "$( cat "${GATE_OUT}" )" '^gate: WOULD HOLD web01 -- living peer\(s\) bravo could not report' \
    "--check reports the same decision"
t_is "$( holds )" "" "and holds nothing"

# Releasing is refused while any living peer's claims are unknown -- even
# though, in this world, the peer that cannot answer is the one that DOES
# claim the guest. Nothing here can know that, which is the point.
world "charlie-mgmt.example.net bravo-mgmt.example.net" bravo web01
WORLD_SSH_MUTE="bravo-mgmt.example.net"
export WORLD_SSH_MUTE
gate release:web01
t_is "${GATE_RC}" "1" \
    "release is refused while a living peer cannot say what it holds"
t_like "$( cat "${GATE_OUT}" )" '^gate: REFUSED web01 -- living peer\(s\) bravo could not report their placement,$' \
    "and names the peer rather than the guest's apparent freedom"

# ---------------------------------------------------------------------------
# Releasing
# ---------------------------------------------------------------------------

world "charlie-mgmt.example.net bravo-mgmt.example.net" bravo web01
gate release:web01
t_is "${GATE_RC}" "1" "release is refused while a peer still claims the guest"
t_like "$( cat "${GATE_OUT}" )" '^gate: REFUSED web01 -- bravo still claims it$' \
    "and it names the peer"

world "" - -
gate release:web01
t_is "${GATE_RC}" "1" "release is refused when not one peer answered"

world "charlie-mgmt.example.net bravo-mgmt.example.net" - -
gate release:web01
t_is "${GATE_RC}" "0" "release succeeds once the peers answer and none claims it"

# ---------------------------------------------------------------------------
# `status`'s home column reads the placement record (decision D-83)
#
# Until promotion existed, every guest a node listed was at home and the
# reporting node's own key was the right answer. Now it is not, and the moment
# it is wrong is the moment somebody is reading `status` to find out what moved.
# ---------------------------------------------------------------------------

world "charlie-mgmt.example.net bravo-mgmt.example.net" - -
STATUS_WARN=0
STATUS_FAIL=0
t_like "$( status_report 1 2>/dev/null )" \
    "^guest${TAB}web01${TAB}jail${TAB}alpha${TAB}yes${TAB}no\$" \
    "a guest nobody has claimed is reported at home on this node"

placement_set web01 charlie
STATUS_WARN=0
STATUS_FAIL=0
t_like "$( status_report 1 2>/dev/null )" \
    "^guest${TAB}web01${TAB}jail${TAB}charlie${TAB}yes${TAB}no\$" \
    "a guest this node hosts away from home is reported at ITS home, not at this one"

STATUS_WARN=0
STATUS_FAIL=0
t_like "$( status_report 0 2>/dev/null )" \
    '^guest web01 +type jail +home charlie +running yes +held no +here alpha$' \
    "and the human form says where it is actually running"

t_done
