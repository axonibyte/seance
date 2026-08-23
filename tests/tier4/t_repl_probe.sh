#!/bin/sh
# Tier 4 -- one liveness probe per peer per tick (D-142's observation, built).
#
# THE MEASUREMENT THIS FILE PROTECTS. `repl` runs every guest-peer pair in a
# process of its own under lockf(1) (D-62), and each of those opens its own
# ssh. Every pair pointing at a node that is DOWN therefore paid
# TRANSPORT_CONNECT_TIMEOUT over again: four guests plus the configuration
# mirror is fifty seconds of a tick spent finding out what the first pair
# already knew, and D-142 measured that as about 40% of the tier-7 battery's
# 2 h 45 m. On a fleet of thirty guests it is five minutes of every tick on
# every surviving node.
#
# The tick now asks each peer ONCE, with the transport's own cheap probe, and
# fails the pairs of a peer that did not answer immediately.
#
# WHY THE ASSERTIONS COUNT ssh CALLS AND NOT SECONDS. A wall-clock assertion
# here would be measuring this workstation, and the shim below answers in
# microseconds anyway. The property is "the dead peer was contacted exactly
# once, and the pairs did not go on to talk to it" -- which is a count of
# invocations, taken from the resource rather than from anybody's exit code.
#
# FAILED, NOT SKIPPED. `skipped` is what a tick says about a guest that was not
# due or is held on another node, and it reads like a healthy line. A guest
# that WAS due, to a peer that is not there, is a failure, and D-141 is the
# entry about what happens when a stopped replication hides behind a
# healthy-looking count.
#
# THE CALLER IS cron(8), CONSTRUCTED FROM SCRATCH (TESTING.md §0): PATH, HOME,
# LOGNAME, USER and SHELL, plus the SEANCE_CBSD_* facts the module's own verb
# wrapper exports -- because the crontab line runs the platform's verb, not
# bin/seance (D-163). Nothing else is in the environment.
#
# WHAT IS FAKED, AND WHAT IS NOT. The tick is the real repl_tick, the transport
# is the real seance_ssh/seance_ssh_probe, the lag records are the real ones
# and the adapter is tests/mock-adapter.subr. `ssh` and `zfs` are scripts on
# PATH -- the world, standing in for the world, found through the same lookup
# the real ones are found through, so that seance runs exactly the commands it
# runs on a node and only the answers change.
#
# THE ENTRY POINT IS repl_tick AND NOT bin/seance, and the reason is D-171 and
# not convenience. The dispatcher now pins the base system in front of the
# caller's PATH before it runs anything -- because CBSD's own dispatch
# directory comes first under cbsdsh and holds a verb called `ssh`, which is
# what made every mesh probe on the fleet fail. That pin is what makes a PATH
# shim unreachable from the dispatcher, so a file that has to script the world
# drives the libraries directly, exactly as tests/tier4/t_ladder.sh has always
# done. The driver below is nine lines and sources what bin/seance sources; the
# dispatcher's own surface is tier 1's (t_verb_*.sh), the pin is
# tests/tier4/t_path_pin.sh's, and the whole path together is tier 6's.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

WORK=$( t_tmpdir )

t_plan 24

WORKDIR="${WORK}/workdir"
STATE="${WORKDIR}/var/db/seance"
mkdir -p "${WORKDIR}/jails-data" "${STATE}/lag"
for g in web01 db01 arc01; do
    mkdir -p "${WORKDIR}/jails-system/${g}"
    printf 'jname="%s"\n' "${g}" > "${WORKDIR}/jails-system/${g}/rc.conf_${g}"
done

# alpha is this node; bravo answers, charlie does not.
CONF="${WORK}/seance.conf"
cat > "${CONF}" <<'EOF'
cadence=900
standby_root=pool0/%n/standby
ssh_port=1

node_alpha_nodename=alpha
node_alpha_mgmt=127.0.0.1
node_alpha_heir=bravo
node_alpha_heir2=charlie

node_bravo_nodename=bravo
node_bravo_mgmt=127.0.0.2
node_bravo_heir=charlie

node_charlie_nodename=charlie
node_charlie_mgmt=127.0.0.3
node_charlie_heir=bravo
EOF

MOCKLOG="${WORK}/mock.log"
: > "${MOCKLOG}"

SHIM="${WORK}/bin"
mkdir -p "${SHIM}"
SSHLOG="${WORK}/ssh.log"
: > "${SSHLOG}"

# ssh: the last two arguments are the target and the command string, which is
# what ssh(1) itself does with them. A peer on the dead list refuses the way a
# host that is not there refuses; a live peer answers the probe and nothing
# else, so that a pair which got past the probe fails on its own conversation
# and can be told apart from one the probe stopped.
cat > "${SHIM}/ssh" <<'EOF'
#!/bin/sh
set -u
target=""
cmd=""
for a in "$@"; do
    target=${cmd}
    cmd=${a}
done
printf '%s\t%s\n' "${target}" "${cmd}" >> "${SEANCE_TEST_SSHLOG}"
addr=${target#*@}
for d in ${SEANCE_TEST_DEAD}; do
    [ "${addr}" = "${d}" ] && exit 255
done
[ "${cmd}" = "exit 0" ] && exit 0
exit 1
EOF

# zfs: enough of a pool for a tick to reach its peers. The mirror dataset lives
# where seance's state does, every guest dataset is mounted under jails-data,
# and everything else succeeds silently.
cat > "${SHIM}/zfs" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${SEANCE_TEST_ZFSLOG}"
verb=$1
shift
case "${verb}" in
    list)
        ds=""
        for a in "$@"; do ds=${a}; done
        case "${ds}" in
            */jails-data) printf 'pool0\n' ;;
            *) printf '%s\n' "${ds}" ;;
        esac
        ;;
    get)
        prop=""
        ds=""
        for a in "$@"; do
            case "${a}" in
                -*) ;;
                value|value,source) ;;
                *) if [ -z "${prop}" ]; then prop=${a}; else ds=${a}; fi ;;
            esac
        done
        case "${prop}" in
            mounted) printf 'yes\n' ;;
            mountpoint)
                case "${ds}" in
                    */seance-sys) printf '%s/sys\n' "${SEANCE_TEST_STATE}" ;;
                    *) printf '%s/jails-data/%s-data\n' "${SEANCE_TEST_WORKDIR}" "${ds##*/}" ;;
                esac
                ;;
            *) printf '\055\n' ;;
        esac
        ;;
    snapshot|set|create|mount|inherit) ;;
    *) ;;
esac
exit 0
EOF

chmod 0755 "${SHIM}/ssh" "${SHIM}/zfs"

# The driver: what bin/seance does for `repl`, minus the dispatcher.
DRIVER="${WORK}/tick.sh"
cat > "${DRIVER}" <<'EOF'
#!/bin/sh
set -u
for f in common policy conf transport notify zfs lineage repl; do
    # shellcheck disable=SC1090
    . "${SEANCE_ROOT}/lib/${f}.subr"
done
# shellcheck disable=SC1090
. "${SEANCE_ADAPTER}"
conf_load "${SEANCE_CONF}" || exit 2
adapter_init || exit 2
seance_tmp_init
repl_tick "$1" "$2" "$3" "$4" "$5"
_rc=$?
[ "${6:-once}" = "twice" ] || exit "${_rc}"
repl_tick "$1" "$2" "$3" "$4" "$5"
EOF

# tick <guest-filter> <peer-filter> <dry> <now> <locked> [twice]
#
# One tick, in cron's environment and nobody else's.
tick()
{
    env -i \
        PATH="${SHIM}:/usr/bin:/bin:/usr/sbin:/sbin" \
        HOME=/root LOGNAME=root USER=root SHELL=/bin/sh \
        SEANCE_CBSD_WORKDIR="${WORKDIR}" \
        SEANCE_CBSD_NODENAME=alpha \
        SEANCE_CONF="${CONF}" \
        SEANCE_ADAPTER="${T_ROOT}/tests/mock-adapter.subr" \
        SEANCE_ROOT="${T_ROOT}" \
        SEANCE_MOCK_NODE=alpha \
        SEANCE_MOCK_WORKDIR="${WORKDIR}" \
        SEANCE_MOCK_LOG="${MOCKLOG}" \
        SEANCE_TEST_SSHLOG="${SSHLOG}" \
        SEANCE_TEST_ZFSLOG="${WORK}/zfs.log" \
        SEANCE_TEST_STATE="${STATE}" \
        SEANCE_TEST_WORKDIR="${WORKDIR}" \
        SEANCE_TEST_DEAD="${DEAD}" \
        sh "${DRIVER}" "$@"
}

# children_run  -- how many per-pair sub-invocations the tick started.
#
# Counted from the adapter's own call log rather than from anything the tick
# said: each pair that is really attempted re-executes the dispatcher under
# lockf(1) (D-62), and that child brings the adapter up exactly once. The
# driver process itself accounts for the first, so the children are the rest.
# A pair whose peer failed the tick's probe must never appear here -- and its
# child, being a fresh dispatcher, would not be running the world this file
# scripts, which is the second reason to count them.
children_run()
{
    awk '$1 == "adapter_init" { n++ } END { print n - 1 }' "${MOCKLOG}"
}

# ssh_to <address>  -- how many ssh invocations went to that peer.
ssh_to()
{
    awk -F "\t" -v a="$1" 'index($1, "@" a) { n++ } END { print n + 0 }' "${SSHLOG}"
}

# probes_to <address>  -- how many of them were the liveness probe.
probes_to()
{
    awk -F "\t" -v a="$1" \
        'index($1, "@" a) && $2 == "exit 0" { n++ } END { print n + 0 }' "${SSHLOG}"
}

DEAD="127.0.0.3"

# The record charlie must not lose. A pair that fails early and forgets what
# the peer was last known to hold takes the fleet's only measure of what a
# promotion onto it would cost (repl_lag_fail).
printf '20260101T000000Z 1767225600 0\n' > "${STATE}/lag/web01.charlie"

# ---------------------------------------------------------------------------
# One tick, one dead peer
# ---------------------------------------------------------------------------

: > "${SSHLOG}"
OUT="${WORK}/tick1.out"
tick "" "" 0 1 0 > "${OUT}" 2>&1
RC=$?

t_isnt "${RC}" "0" "a tick that could not replicate to a dead peer fails"
t_like "$( cat "${OUT}" )" \
    '^repl: 3 guests x 4 pairs, 0 ok, 4 failed, 1 skipped, 0 in progress$' \
    "and the verdict line counts the dead peer's pairs as FAILED, not skipped"
t_like "$( cat "${OUT}" )" \
    '^repl: configuration mirror: 2 pairs, 0 ok, 2 failed, 0 in progress$' \
    "and the configuration mirror's own line counts its dead pair the same way"

t_is "$( probes_to 127.0.0.3 )" "1" \
    "the dead peer was probed ONCE in the whole tick"
t_is "$( ssh_to 127.0.0.3 )" "1" \
    "and that probe is the ONLY thing sent to it: two guest pairs and the mirror cost one connect attempt between them"

t_is "$( probes_to 127.0.0.2 )" "1" \
    "the live peer was probed once too -- per peer, not per pair"
t_is "$( children_run )" "3" \
    "and its three pairs -- two guests and the configuration mirror -- each ran, exactly as before"

# The dead peer's three pairs would be three more children: the whole point is
# that a pair whose peer did not answer costs nothing beyond the one probe.
t_is "$( ssh_to 127.0.0.1 )" "0" \
    "the corpse's own address is not probed: a tick asks the peers it replicates to"

t_like "$( cat "${OUT}" )" \
    'peer charlie \(127\.0\.0\.3\) did not answer this tick.s liveness probe' \
    "the probe's own failure is reported once, naming the peer and its address"
t_like "$( cat "${OUT}" )" \
    'repl web01->charlie: peer charlie did not answer the tick.s liveness probe' \
    "and each pair says what stopped IT, in the pair's own voice"
t_like "$( cat "${OUT}" )" \
    'repl seance-sys->charlie: peer charlie did not answer the tick.s liveness probe' \
    "the configuration mirror included"
t_unlike "$( cat "${OUT}" )" 'peer bravo did not answer' \
    "and nothing is said about the peer that did answer"

t_like "$( cat "${STATE}/lag/web01.charlie" )" \
    '^20260101T000000Z [0-9]+ 1$' \
    "the failed pair's lag record MOVED ON with rc 1 and kept what charlie was last known to hold"

# ---------------------------------------------------------------------------
# The probe is per tick, and is not remembered
# ---------------------------------------------------------------------------

: > "${SSHLOG}"
tick "" "" 0 1 0 > "${WORK}/tick2.out" 2>&1

t_is "$( probes_to 127.0.0.3 )" "1" \
    "the next tick probes the peer again: a peer that was down at 03:00 is not evidence about 03:05"
t_is "$( ssh_to 127.0.0.3 )" "1" \
    "and still pays exactly one connect attempt for it"

# AND IT IS THE TICK'S, NOT THE PROCESS'S. cron gives every tick a process of
# its own, so the two ticks above would have re-probed even if the answers were
# never cleared -- which is exactly the kind of property that is true by
# accident until somebody calls repl_tick twice in one process.
: > "${SSHLOG}"
tick "" "" 0 1 0 twice > "${WORK}/twoticks.out" 2>&1

t_is "$( probes_to 127.0.0.3 )" "2" \
    "two ticks in ONE process probe twice: the answers are the tick's, not the process's"

# ---------------------------------------------------------------------------
# A dry run contacts nobody, so it does not probe either
# ---------------------------------------------------------------------------

: > "${SSHLOG}"
tick "" "" 1 1 0 > "${WORK}/dry.out" 2>&1
DRY_RC=$?

t_is "${DRY_RC}" "0" "a dry run says what it would send and exits 0"
t_is "$( ssh_to 127.0.0.3 )" "0" "and reaches for no peer at all -- no probe, no pair"
t_is "$( ssh_to 127.0.0.2 )" "0" "the live one included"

# ---------------------------------------------------------------------------
# A locked sub-invocation does not probe: its parent has already asked
# ---------------------------------------------------------------------------

: > "${SSHLOG}"
tick web01 bravo 0 1 1 > "${WORK}/locked.out" 2>&1

t_is "$( probes_to 127.0.0.2 )" "0" \
    "the per-pair sub-invocation does not repeat the tick's probe"
if [ "$( ssh_to 127.0.0.2 )" -gt 0 ]; then
    t_ok "-- it does the pair, which is what its parent locked it for"
else
    t_not_ok "-- it does the pair, which is what its parent locked it for"
fi

# ---------------------------------------------------------------------------
# One pair, named on the command line, to a peer that is not there
# ---------------------------------------------------------------------------

: > "${SSHLOG}"
tick web01 charlie 0 1 0 > "${WORK}/one.out" 2>&1
ONE_RC=$?

t_isnt "${ONE_RC}" "0" "an operator's single pair to an unreachable peer reports failure"
t_is "$( ssh_to 127.0.0.3 )" "1" "having tried once and stopped"
t_like "$( awk 'NF > 0 { line = $0 } END { print line }' "${WORK}/one.out" )" \
    '^repl: 1 guests x 1 pairs, 0 ok, 1 failed, 0 skipped, 0 in progress$' \
    "and the verdict line is the tick's, with its counts unchanged in meaning"

t_done
