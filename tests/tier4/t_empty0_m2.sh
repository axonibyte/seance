#!/bin/sh
# Tier 4 -- empty output with a success status, across M2's seams.
#
# TESTING.md §5 names this as a test CLASS rather than a case: "the
# crashed-verifier lesson encoded as a test", because the August defect was a
# verifier whose crash produced no output and exit 0, and every caller read
# that as "nothing wrong". M1 covered it in the replication path (D-88) and the
# fence rung has carried a row for it since U6. This file walks M2's remaining
# seams and asks each of them the same question.
#
# THE SEAMS, and what each of them would mean if a silence were read as a yes:
#
#   zfs mount        exits 0 and the dataset is not mounted -> the guest is
#                    registered and STARTED over an empty directory, or over
#                    whatever the parent had at that path. The data arrived and
#                    the guest does not have it.
#   the running probe  the platform says nothing when asked whether the guest
#                    it just started is running -> a promotion reports success
#                    for a guest that is not up.
#   the peer's placement  a peer answers the mesh query with nothing at all ->
#                    its claims read as absent, and the guest it is running is
#                    started here too (D-96).
#   the adapter's dataset list  the interim answers a failback's snapshot step
#                    with no datasets -> a final snapshot of nothing, and a
#                    reverse stream from it.
#
# The fifth seam of the same shape -- an interim that says it snapshotted and
# does not say WHAT, so that the reverse stream would be sent from a name
# nobody returned -- is asserted where its fixture already lives, in
# tests/tier4/t_failback.sh's WORLD_SNAP_MUTE rows, and is named here so that
# the set is readable in one place.
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
# shellcheck source=../../lib/lineage.subr
. "${T_ROOT}/lib/lineage.subr"
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
# shellcheck source=../../lib/promote.subr
. "${T_ROOT}/lib/promote.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/failback.subr
. "${T_ROOT}/lib/failback.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../mock-adapter.subr
. "${T_ROOT}/tests/mock-adapter.subr"

DIR=$( t_tmpdir )

SEANCE_TMP_REGISTRY="${DIR}/registry"
: > "${SEANCE_TMP_REGISTRY}"
export SEANCE_TMP_REGISTRY
t_at_exit 'seance_tmp_cleanup'

NOTIFY_TIMEOUT=1

# --- the mesh, and syslog ---------------------------------------------------
SHIM="${DIR}/bin"
mkdir -p "${SHIM}"

cat > "${SHIM}/ssh" <<'EOF'
#!/bin/sh
# A peer that answers exactly as WORLD_ANSWER says, so that "answered with
# nothing" and "did not answer" are two different experiments.
set -u
prev=""
cur=""
for a in "$@"; do
    prev=${cur}
    cur=$a
done
addr=${prev#*@}

case "${cur}" in
    "exit 0") exit 0 ;;
esac

case "${WORLD_ANSWER:-full}" in
    full)
        printf 'placement\tweb01\talpha\n'
        printf 'placement: 1 guest(s) hosted away from home\n'
        exit 0
        ;;
    empty)      exit 0 ;;
    blank)      printf '\n\n'; exit 0 ;;
    noverdict)  printf 'placement\tweb01\talpha\n'; exit 0 ;;
    dead)       echo "ssh: connect to host ${addr}: Connection refused" >&2; exit 255 ;;
esac
exit 0
EOF

cat > "${SHIM}/logger" <<'EOF'
#!/bin/sh
set -u
printf '%s\n' "$*" >> "${LOGGER_LOG}"
exit 0
EOF
chmod 0755 "${SHIM}/ssh" "${SHIM}/logger"
LOGGER_LOG="${DIR}/logger.log"
export LOGGER_LOG
PATH="${SHIM}:${PATH}"
export PATH

# --- one fleet --------------------------------------------------------------
CONF="${DIR}/seance.conf"
cat > "${CONF}" <<'EOF'
cadence=900
standby_root=pool0/%n/standby
node_alpha_nodename=alpha
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
EOF
conf_load "${CONF}" || { echo "the fixture configuration did not load" >&2; exit 2; }

SEANCE_STATE_DIR="${DIR}/state"
SEANCE_RUN_DIR="${DIR}/run"
export SEANCE_STATE_DIR SEANCE_RUN_DIR
mkdir -p "${SEANCE_STATE_DIR}" "${SEANCE_RUN_DIR}"

SEANCE_MOCK_NODE=bravo
SEANCE_MOCK_WORKDIR="${DIR}/workdir"
SEANCE_MOCK_LOG="${DIR}/mock.log"
SEANCE_MOCK_SCRIPT="${DIR}/mock.script"
export SEANCE_MOCK_NODE SEANCE_MOCK_WORKDIR SEANCE_MOCK_LOG SEANCE_MOCK_SCRIPT
mkdir -p "${SEANCE_MOCK_WORKDIR}/jails-system" "${SEANCE_MOCK_WORKDIR}/jails-data/web01-data" \
         "${SEANCE_MOCK_WORKDIR}/jails-data"
# web01's configuration TRAVELS in this world: its sysdir is a symlink into the
# replica's data directory, the way a CBSD VM's is (and the pseudo-cluster's
# sys/ child dataset). A plain jails-system/web01 holding a readable file is,
# since D-187, the survivor's stale copy and is refused -- rightly, which is
# why this fixture no longer models one.
ln -s "${SEANCE_MOCK_WORKDIR}/jails-data/web01-data" "${SEANCE_MOCK_WORKDIR}/jails-system/web01"
printf 'name=web01\n' > "${SEANCE_MOCK_WORKDIR}/jails-data/web01-data/rc.conf_web01"
: > "${SEANCE_MOCK_SCRIPT}"

PROMOTE_DEAD=alpha
PROMOTE_OPERATOR=tester
PROMOTE_TMPDIR="${DIR}/promote"
mkdir -p "${PROMOTE_TMPDIR}"
PROMOTE_FORCE=""
PROMOTE_EVIDENCE="fence:mock"

ROOT=pool0/bravo/standby/alpha/web01

# --- the pool, as far as promote can see it ---------------------------------
#
# W_MOUNT says what `zfs mount` does: "real" mounts, "lie" exits 0 and mounts
# nothing. The second is the injection this file is about, and it is injected
# at the wrapper because that is the seam promote reaches ZFS through.
W_MOUNT=real
W_MOUNTED=""

# shellcheck disable=SC2329
zfs_filesystems_r() { printf '%s\n' "$1"; }

# zfs_get mountpoint: where this world's replicas mount, by the same layout the
# mock adapter answers (a jail at jails-data/<n>-data, a VM at vm/<n>), so that
# promote_config_travelled (D-187) can tell a sysdir INSIDE the replica from a
# survivor's stale copy of the same name.
zfs_get()
{
    case "$1" in
        mountpoint)
            case "${2##*/}" in
                db01) printf '%s/vm/db01\n' "${SEANCE_MOCK_WORKDIR}" ;;
                *)    printf '%s/jails-data/%s-data\n' "${SEANCE_MOCK_WORKDIR}" "${2##*/}" ;;
            esac
            ;;
        *) return 1 ;;
    esac
}
# shellcheck disable=SC2329
zfs_volumes_r() { return 0; }
# shellcheck disable=SC2329
zfs_set() { return 0; }
# shellcheck disable=SC2329
zfs_inherit() { return 0; }
# shellcheck disable=SC2329
zfs_unmount() { W_MOUNTED=""; return 0; }
# shellcheck disable=SC2329
zfs_exists() { return 0; }
# shellcheck disable=SC2329
zfs_mounted() { [ "${W_MOUNTED}" = "$1" ]; }
# shellcheck disable=SC2329
zfs_mount()
{
    [ "${W_MOUNT}" = "real" ] && W_MOUNTED=$1
    return 0
}

OUT="${DIR}/out"

t_plan 17

# ---------------------------------------------------------------------------
# `zfs mount` exits 0 and the dataset is not mounted
# ---------------------------------------------------------------------------

W_MOUNT=real
W_MOUNTED=""
promote_mount_ceremony web01 "${ROOT}" /wd/jails-data/web01-data > "${OUT}" 2>&1
t_is "$?" "0" "the mount ceremony succeeds when the mount really happens"
t_like "$( cat "${OUT}" )" "^  mounted ${ROOT} at /wd/jails-data/web01-data\$" \
    "and says where it mounted it"

W_MOUNT=lie
W_MOUNTED=""
promote_mount_ceremony web01 "${ROOT}" /wd/jails-data/web01-data > "${OUT}" 2>&1
t_isnt "$?" "0" \
    "a zfs mount that exits 0 and mounts nothing FAILS the ceremony"
t_like "$( cat "${OUT}" )" 'still not mounted' \
    "and says exactly that, rather than reporting a mount it did not get"
t_unlike "$( cat "${OUT}" )" "^  mounted ${ROOT} " \
    "and it does not claim to have mounted it"

# ---------------------------------------------------------------------------
# The platform says nothing about the guest it was just asked to start
# ---------------------------------------------------------------------------

promote_guest_run()
{
    : > "${SEANCE_MOCK_LOG}"
    W_MOUNT=real
    W_MOUNTED=""
    rm -f "${SEANCE_STATE_DIR}/placement" "${SEANCE_STATE_DIR}/succession.log"
    promote_guest_promote web01 "${ROOT}" 20260101T000000Z bravo \
        "$( date -u +%s )" pool0/bravo/standby > "${OUT}" 2>&1
}

: > "${SEANCE_MOCK_SCRIPT}"
promote_guest_run
t_is "$?" "0" "a guest whose platform answers properly is promoted"
t_like "$( cat "${SEANCE_MOCK_LOG}" )" '^adapter_guest_start web01$' \
    "and it was started"

printf 'adapter_guest_running web01\tempty0\n' > "${SEANCE_MOCK_SCRIPT}"
promote_guest_run
t_isnt "$?" "0" \
    "a platform that says NOTHING about whether the guest is running fails the promotion"
t_like "$( cat "${OUT}" )" 'does not report it running' \
    "and the reason names the probe, not the start"
t_is "$( cat "${SEANCE_STATE_DIR}/placement" 2>/dev/null || printf '' )" "" \
    "and no placement claim is recorded for a guest nobody can say is up"
: > "${SEANCE_MOCK_SCRIPT}"

# ---------------------------------------------------------------------------
# A peer that answers the mesh query with nothing
# ---------------------------------------------------------------------------

claims()
{
    WORLD_ANSWER=$1
    export WORLD_ANSWER
    placement_remote bravo > "${DIR}/claims" 2> /dev/null
}

claims full
t_is "$( awk -F '\t' '$1 == "peer" { print $3 }' "${DIR}/claims" )" "answered" \
    "a peer that answers with records and a verdict line has answered"

claims empty
t_is "$( awk -F '\t' '$1 == "peer" { print $3 }' "${DIR}/claims" )" "failed" \
    "a peer that exits 0 and says NOTHING has not answered: empty is not 'no claims'"
t_is "$( placement_silent "${DIR}/claims" )" "bravo " \
    "and it is named as the peer that could not be read (D-96)"

claims blank
t_is "$( awk -F '\t' '$1 == "peer" { print $3 }' "${DIR}/claims" )" "failed" \
    "and neither has one that answers with two empty lines"

claims noverdict
t_is "$( awk -F '\t' '$1 == "peer" { print $3 }' "${DIR}/claims" )" "failed" \
    "nor one whose answer stops before its verdict line: half a placement is not a placement"

# ---------------------------------------------------------------------------
# The interim that says it did something and does not say what
# ---------------------------------------------------------------------------

# The adapter answers `adapter_guest_datasets` with rc 0 and no rows. A final
# snapshot needs a dataset to take it of, and "the list is empty" is not one.
printf 'adapter_guest_datasets web01\tempty0\n' > "${SEANCE_MOCK_SCRIPT}"
failback_assist web01 snapshot > "${OUT}" 2>&1
t_isnt "$?" "0" \
    "the interim refuses to snapshot a guest whose dataset list came back empty"
t_like "$( cat "${OUT}" )" 'reported no datasets' \
    "and says the list was empty rather than snapshotting nothing"
: > "${SEANCE_MOCK_SCRIPT}"

t_done
