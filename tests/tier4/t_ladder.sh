#!/bin/sh
# Tier 4 -- the whole promotion ladder, as a truth table (TESTING.md §5).
#
# Every rung crossed with every outcome infrastructure can produce, and every
# crossing with ONE expected disposition. The table is tests/tier4/ladder.tsv;
# this file builds a world per row and drives lib/promote.subr through it.
#
# WHAT IS FAKED, AND WHAT IS NOT. The ladder is the real one -- promote_run,
# every rung, the real policy engine, the real config parser, the real notify
# path. What stands in for the world is the world:
#
#   ssh, ping   shell scripts on PATH, scripted by their OWN environment.
#               seance runs the same seance_ssh and the same probe it runs on a
#               node; what changes is who answers. There is deliberately no
#               "pretend the peer is down" flag inside seance, because a code
#               path only the tests take is a code path nobody else exercises
#               (the reasoning D-35 used to reject a test-only override).
#   fence_mock  tests/drivers/fence_mock, a real executable found through the
#               same PATH lookup a shipped driver would be, producing every
#               answer the exit-code contract names -- including the three that
#               are not answers: a hang, a success with nothing to say, and a
#               success with the wrong thing to say.
#   the adapter tests/mock-adapter.subr, the same one every other tier-4 file
#               uses.
#   local ZFS   the lib/zfs.subr wrappers, replaced in THIS shell. promote.subr
#               reaches local ZFS only through them, which is what makes a
#               workstation with no pool able to run the ceremony.
#
# THE ROWS THAT MATTER MOST are the ones where the ladder is asked to proceed
# on something it does not know: a fence that timed out, a fence that exited 0
# with nothing to say, a snapshot listing that came back empty. None of them
# may become permission, and none of them may be reachable by --force except in
# the one direction D-44 item 1 allows.
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
# shellcheck source=../../lib/carp.subr
. "${T_ROOT}/lib/carp.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/gate.subr
. "${T_ROOT}/lib/gate.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/promote.subr
. "${T_ROOT}/lib/promote.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../mock-adapter.subr
. "${T_ROOT}/tests/mock-adapter.subr"

TAB=$( printf '\t.' )
TAB=${TAB%.}

TABLE="${T_ROOT}/tests/tier4/ladder.tsv"

# The temporary-directory registry, wired to the HARNESS's cleanup rather than
# to seance's own: seance_tmp_init installs a trap on EXIT, which would replace
# the one the harness set and take every other cleanup with it.
SEANCE_TMP_REGISTRY=$( t_tmpdir )/registry
: > "${SEANCE_TMP_REGISTRY}"
export SEANCE_TMP_REGISTRY
t_at_exit 'seance_tmp_cleanup'

# The notify budget, lowered in this shell so that the "notify_cmd hangs" rows
# cost a second rather than half a minute. It is a library constant precisely
# so that a test can do this without seance carrying an environment override.
NOTIFY_TIMEOUT=1

NOW=$( date -u +%s )
OP=$( promote_operator )

# ---------------------------------------------------------------------------
# The shims: what the world says when seance asks it
# ---------------------------------------------------------------------------

SHIM=$( t_tmpdir )/bin
mkdir -p "${SHIM}"

cat > "${SHIM}/ssh" <<'EOF'
#!/bin/sh
# The mesh, such as it is. WORLD_SSH_ALIVE lists the addresses that answer;
# everything else is a connection refused, which is what an ssh to a dead node
# actually looks like.
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
    "exit 0")
        exit 0
        ;;
    "seance placement")
        case " ${WORLD_SSH_MUTE:-} " in
            *" ${addr} "*)
                echo "seance: not found" >&2
                exit 127
                ;;
        esac
        [ -r "${WORLD_DIR}/claims.${addr}" ] && cat "${WORLD_DIR}/claims.${addr}"
        echo "placement: answered"
        exit 0
        ;;
    *freebsd-version*)
        [ -r "${WORLD_DIR}/kernel.${addr}" ] && cat "${WORLD_DIR}/kernel.${addr}"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF

cat > "${SHIM}/ping" <<'EOF'
#!/bin/sh
set -u
while [ $# -gt 1 ]; do shift; done
addr=$1
case " ${WORLD_PING_ALIVE:-} " in
    *" ${addr} "*) exit 0 ;;
esac
exit 1
EOF

cat > "${SHIM}/logger" <<'EOF'
#!/bin/sh
# syslog, redirected to a file: a test suite has no business filling the
# workstation's log, and this way the "no notify_cmd means syslog only" path is
# observable rather than merely unobjectionable.
set -u
printf '%s\n' "$*" >> "${WORLD_DIR}/logger.log"
exit 0
EOF

# The debounce wait, injected. It records the number of seconds it was asked
# for and returns at once, so the rung-1 path is taken in full at no cost --
# the wait itself is the one thing in the ladder whose only observable effect
# is time passing (D-51's reasoning, applied to a sleep instead of a timeout).
SLEEPLOG=$( t_tmpdir )/slept
# shellcheck disable=SC2016
#   The single quotes are the point: "$1" is source text of the script being
#   written, not an expansion for this shell.
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s"\nexit 0\n' "${SLEEPLOG}" \
    > "${SHIM}/fakesleep"

cp "${T_ROOT}/tests/drivers/fence_mock" "${SHIM}/fence_mock"
chmod 0755 "${SHIM}/ssh" "${SHIM}/ping" "${SHIM}/logger" "${SHIM}/fence_mock" \
    "${SHIM}/fakesleep"

PATH="${SHIM}:${PATH}"
export PATH

# ---------------------------------------------------------------------------
# The local disk, such as it is
#
# promote.subr reaches local ZFS only through lib/zfs.subr's wrappers, so
# standing in for them here stands in for the disk without standing in for one
# line of the ladder.
# ---------------------------------------------------------------------------

W_ESTATE=""
W_GUESTTYPE=jail
W_ZFSLOG=""

# shellcheck disable=SC2329
#   Called by lib/promote.subr, which shellcheck checks as a separate file.
zfs_children()
{
    [ -n "${W_ESTATE}" ] || return 1
    printf '%s\n' "${W_ESTATE}"
}

# shellcheck disable=SC2329
zfs_filesystems_r()
{
    printf '%s\n' "$1"
    printf '%s/data\n' "$1"
}

# shellcheck disable=SC2329
zfs_volumes_r()
{
    [ "${W_GUESTTYPE}" = "bhyve" ] || return 0
    printf '%s/dsk1.vhd\n' "$1"
}

W_MIRROR=ok
W_MIRROR_GUEST=web01

# WHAT THE REPLICA SAYS IT IS A REPLICA OF (D-183). Three shapes, and the
# middle one is the fleet's:
#
#   named       the replica's dataset basename happens to equal the guest's
#               name AND the tick recorded the name. The textbook shape, and
#               the one every fixture in this repository used to assume.
#   fleetshape  the basename is <guest>-data, because that is what the
#               PLATFORM called the source dataset when it created the guest,
#               and the tick recorded the guest's real name. Deriving a name
#               from this basename produces a guest that does not exist --
#               which is exactly what refused a correct promotion on the first
#               real fleet, with the home node already down.
#   unnamed     nothing recorded a name. The upgrade window, and the state
#               a hand-made dataset is in. Must be refused BY DATASET.
W_REPLICA=named
W_REPLICA_BASE=""

# shellcheck disable=SC2329
zfs_get()
{
    case "$1" in
        seance:guest)
            # `zfs get` of an unset user property prints '-' and exits 0; a
            # mock that printed nothing would be testing a shape the real
            # command never produces.
            case "${W_REPLICA}" in
                unnamed) printf '%s\n' '-' ;;
                *)
                    case "$2" in
                        *"/${REPL_SYS_GUEST}") printf '%s\n' '-' ;;
                        *) printf '%s\n' "${W_MIRROR_GUEST}" ;;
                    esac
                    ;;
            esac
            return 0
            ;;
        mountpoint)
            # What this world was last told to set (w_mountpoint), which is
            # what promote_config_travelled reads to decide whether a guest's
            # sysdir resolves inside its replica (D-187).
            w_mountpoint "$2"
            return $?
            ;;
        *)
            t_diag "zfs_get: this fixture has no answer for property [$1] on [$2]"
            return 1
            ;;
    esac
}

# What the guest's own configuration says about where its data lives, and
# whether that configuration travels inside the guest's own replica (D-181).
W_DATA=none
W_DATAPATH=""
W_TRAVELS=0

# shellcheck disable=SC2329
zfs_set()
{
    # THE MOUNTPOINT MAP is how this fixture learns which scratch path a
    # read-only borrow put a dataset at -- the same way the real pair of
    # commands works, with the code telling the pool rather than the other way
    # round. It is a map and no longer one variable for the mirror, because
    # the ceremony now borrows the guest's OWN replica too.
    case "$1" in
        mountpoint=*)
            printf '%s\t%s\n' "$2" "${1#mountpoint=}" >> "${ROWDIR}/mountpoints"
            ;;
    esac
    printf 'set %s %s\n' "$1" "$2" >> "${W_ZFSLOG}"
}

# w_mountpoint <dataset>  -- the last mountpoint this world was told to set.
w_mountpoint()
{
    [ -r "${ROWDIR}/mountpoints" ] || return 1

    awk -F '\t' -v d="$1" \
        '$1 == d { p = $2 } END { if (p == "") { exit 1 } ; print p }' \
        "${ROWDIR}/mountpoints"
}

# w_rcconf <guest>  -- the guest's own configuration, as this world's platform
# writes one. ONE WRITER for all three places it can appear (the mirror, the
# replica, ${jailsysdir}), because a row in which the mount path and the
# registration disagree is a row about a fixture and not about seance.
w_rcconf()
{
    printf 'name=%s\n' "$1"

    case "${W_DATA}" in
        none)     ;;
        zero)     printf 'data=0\n' ;;
        relative) printf 'data=jails-data/%s-data\n' "$1" ;;
        *)        printf 'data=%s\n' "${W_DATAPATH}" ;;
    esac
}

# shellcheck disable=SC2329
zfs_exists()
{
    [ "${W_MIRROR}" != "absent" ]
}

# shellcheck disable=SC2329
zfs_mount_ro()
{
    local _at

    printf 'mount-ro %s\n' "$1" >> "${W_ZFSLOG}"

    _at=$( w_mountpoint "$1" ) || return 0

    case "$1" in
        *"/${REPL_SYS_GUEST}")
            # The dead node's configuration mirror.
            [ "${W_MIRROR}" = "ok" ] || return 0
            mkdir -p "${_at}/${W_MIRROR_GUEST}" || return 1
            w_rcconf "${W_MIRROR_GUEST}" \
                > "${_at}/${W_MIRROR_GUEST}/rc.conf_${W_MIRROR_GUEST}"
            ;;
        *)
            # The guest's own replica, which carries its configuration only
            # when this world says the configuration travels (D-84 item 3).
            [ "${W_TRAVELS}" = "1" ] || return 0
            [ "$1" = "${W_GUESTROOT}" ] || return 0
            w_rcconf "${W_MIRROR_GUEST}" > "${_at}/rc.conf_${W_MIRROR_GUEST}"
            ;;
    esac

    return 0
}

# shellcheck disable=SC2329
zfs_unmount()
{
    printf 'unmount %s\n' "$1" >> "${W_ZFSLOG}"
}

# shellcheck disable=SC2329
zfs_inherit()
{
    printf 'inherit %s %s\n' "$1" "$2" >> "${W_ZFSLOG}"
}

# W_MOUNTS is the mount table this fixture keeps, because promote now ASKS
# whether the mount happened rather than believing `zfs mount`'s exit status
# (the empty-output-with-success class, applied to a mount --
# tests/tier4/t_empty0_m2.sh is the file about it). A fixture whose zfs_mounted
# always said "no" would fail every ceremony; one that always said "yes" would
# make the new check unfalsifiable. It says what this fixture's own zfs_mount
# did.
W_MOUNTS=""

# shellcheck disable=SC2329
zfs_mount()
{
    local _at

    printf 'mount %s\n' "$1" >> "${W_ZFSLOG}"
    W_MOUNTS="${W_MOUNTS} $1"

    # A MOUNTED DATASET HAS A DIRECTORY AT ITS MOUNTPOINT, and the ceremony's
    # next steps walk into it: a VM's ${jailsysdir}/<n> is a symlink to its
    # data directory, and the configuration restore writes THROUGH that link.
    # A fixture that logged the mount without making the directory made every
    # such row fail on a dangling symlink -- a fact about the fixture, not
    # about seance.
    _at=$( w_mountpoint "$1" ) || return 0
    mkdir -p "${_at}" || return 1

    return 0
}

# shellcheck disable=SC2329
zfs_mounted()
{
    case " ${W_MOUNTS} " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# shellcheck disable=SC2329
zfs_rollback_r()
{
    printf 'rollback %s@%s\n' "$1" "$2" >> "${W_ZFSLOG}"
}

# --- the recursive snapshot listing, as a TREE ------------------------------
#
# The mock answers for one dataset; a guest is a tree, and D-85 is entirely
# about what happens when the datasets of that tree are at different instants.
# So the listing seam is composed here from the mock's own output -- every name
# still generated by the REAL formatter at the REAL cadence, so no fixture name
# is a shape seance would not itself have written -- and then filtered to the
# dataset the caller asked about, exactly as `zfs list -r` would.

W_GUESTROOT=""
W_TREE=coherent

# THE CRASHED VERIFIER, and it has to be here rather than in the mock's script.
#
# `lineage=empty0` means the snapshot listing exits 0 having printed NOTHING --
# the August catalogue's crashed checker, whose silence read as success. It used
# to be scripted into the mock with a key built from ${W_ESTATE}, which is TWO
# lines: the script came out malformed, the mock answered the contract error it
# should have, and the row passed while measuring a different failure entirely.
# Found by tests/rediscovery/verifier-masks-crash.patch, which reverts the
# protection this row exists for and which this row did not notice.
W_LINEAGE=fresh

# shellcheck disable=SC2329
lineage_listing()
{
    local _want _root _base _ahead _ts

    _want=$1

    if [ "${W_LINEAGE}" = "empty0" ]; then
        return 0
    fi

    # The configuration mirror is a tree of its own, and it has a real lineage:
    # if it did not, it would be kept out of the estate by having no snapshots
    # rather than by the rule that is supposed to keep it out, and the
    # assertion that seance walks past it would be asserting nothing. (Found
    # by the estate-includes-sysmirror mutation check, which passed until this
    # was fixed.)
    case "${_want}" in
        *"/${REPL_SYS_GUEST}"|*"/${REPL_SYS_GUEST}/"*)
            mock_zfs_list "pool0/bravo/standby/alpha/${REPL_SYS_GUEST}"
            return $?
            ;;
    esac

    _root=${W_GUESTROOT}

    _base=$( mock_zfs_list "${_root}" ) || return $?

    {
        printf '%s\n' "${_base}"

        case "${W_TREE}" in
            coherent)
                printf '%s\n' "${_base}" | sed -e "s|^${_root}@|${_root}/data@|"
                ;;
            child-ahead)
                printf '%s\n' "${_base}" | sed -e "s|^${_root}@|${_root}/data@|"
                # One more instant on the CHILD only: what an interrupted tick
                # leaves behind when the root's send died and the child's did
                # not (D-64, observed in tests/tier6/t_interrupt.sh).
                _ts=$( pol_epoch_to_ts $(( SEANCE_MOCK_LINEAGE_NOW + 900 )) )
                _ahead=$( pol_snap_format alpha "${_ts}" )
                printf '%s/data@%s\n' "${_root}" "${_ahead}"
                ;;
            child-foreign)
                printf '%s/data@zrepl_20200101_000000_000\n' "${_root}"
                ;;
        esac
    } | awk -F '@' -v d="${_want}" 'NF == 2 && ($1 == d || index($1, d "/") == 1)'
}

# ---------------------------------------------------------------------------
# Building a world from a row's spec
# ---------------------------------------------------------------------------

ROWDIR=""

# world_build <spec>
world_build()
{
    local _spec _kv _k _v _replica
    local _nodes _reach _dead _fence _lineage _claim _peermute _kernel _guest _notify
    local _sysdir _mirror _tree _auto _fleetauto _armed _carp _vhid _succ
    local _override _data _platform
    local _conf _wd _n _lnow

    _spec=$1

    _nodes=3
    _reach=1
    _dead=no
    _fence=off
    _lineage=fresh
    _claim=-
    _peermute=-
    _kernel=same
    _guest=web01
    _notify=none
    _sysdir=present
    _mirror=ok
    _tree=coherent
    _auto=0
    _fleetauto=1
    _armed=yes
    _carp=MASTER
    _vhid=yes
    _succ=default
    _override=-
    _data=none
    _platform=agree
    _replica=named

    [ "${_spec}" = "-" ] && _spec=""

    for _kv in ${_spec}; do
        _k=${_kv%%=*}
        _v=${_kv#*=}
        case "${_k}" in
            nodes)   _nodes=${_v} ;;
            reach)   _reach=${_v} ;;
            dead)    _dead=${_v} ;;
            fence)   _fence=${_v} ;;
            lineage) _lineage=${_v} ;;
            claim)   _claim=${_v} ;;
            peermute) _peermute=${_v} ;;
            kernel)  _kernel=${_v} ;;
            guest)   _guest=${_v} ;;
            notify)  _notify=${_v} ;;
            sysdir)  _sysdir=${_v} ;;
            mirror)  _mirror=${_v} ;;
            tree)    _tree=${_v} ;;
            auto)    _auto=${_v} ;;
            fleetauto) _fleetauto=${_v} ;;
            armed)   _armed=${_v} ;;
            carp)    _carp=${_v} ;;
            vhid)    _vhid=${_v} ;;
            succ)    _succ=${_v} ;;
            override) _override=${_v} ;;
            data)     _data=${_v} ;;
            platform) _platform=${_v} ;;
            replica)  _replica=${_v} ;;
            *)
                t_diag "world_build: unknown setting: ${_kv}"
                return 2
                ;;
        esac
    done

    # nodes=4 needs a fourth living node for reach=2 to mean anything.
    [ "${_nodes}" = "4" ] && [ "${_reach}" = "1" ] && _reach=1

    ROWDIR=$( t_tmpdir )
    WORLD_DIR=${ROWDIR}
    export WORLD_DIR

    _wd="${ROWDIR}/workdir"
    mkdir -p "${_wd}/jails-system" "${_wd}/jails-data" "${_wd}/vm" "${_wd}/etc"

    SEANCE_MOCK_WORKDIR=${_wd}
    SEANCE_MOCK_NODE=bravo
    SEANCE_MOCK_KERNEL="15.1-RELEASE-p2"
    SEANCE_MOCK_LOG="${ROWDIR}/mock.log"
    SEANCE_MOCK_SCRIPT="${ROWDIR}/mock.script"
    export SEANCE_MOCK_WORKDIR SEANCE_MOCK_NODE SEANCE_MOCK_KERNEL
    export SEANCE_MOCK_LOG SEANCE_MOCK_SCRIPT
    : > "${SEANCE_MOCK_SCRIPT}"

    SEANCE_STATE_DIR="${ROWDIR}/state"
    SEANCE_RUN_DIR="${ROWDIR}/run"
    export SEANCE_STATE_DIR SEANCE_RUN_DIR
    mkdir -p "${SEANCE_STATE_DIR}" "${SEANCE_RUN_DIR}"

    W_ZFSLOG="${ROWDIR}/zfs.log"
    : > "${W_ZFSLOG}"
    W_MOUNTS=""

    FENCE_MOCK_LOG="${ROWDIR}/fence.log"
    FENCE_MOCK_MODE=off
    FENCE_MOCK_SLEEP=3
    export FENCE_MOCK_LOG FENCE_MOCK_MODE FENCE_MOCK_SLEEP

    # --- where this guest's own configuration says its data lives ---------
    #
    # `none` is the world every row before D-181 described: a configuration
    # that states no data path at all, so the ceremony falls back to where this
    # platform CREATES a guest of that type -- which is what it used to do
    # unconditionally, and what it must still do when there is nothing to
    # observe. `jailshape` is the first real fleet, verbatim: a bhyve guest
    # whose data is at the jail-shaped path.
    W_DATA=${_data}
    W_TRAVELS=0
    case "${_data}" in
        none|zero)  W_DATAPATH="" ;;
        relative)   W_DATAPATH="" ;;
        jailshape)  W_DATAPATH="${_wd}/jails-data/${_guest}-data" ;;
        travels)
            W_DATAPATH="${_wd}/jails-data/${_guest}-data"
            W_TRAVELS=1
            ;;
        *) t_diag "world_build: unknown data: ${_data}"; return 2 ;;
    esac

    W_MIRROR=${_mirror}
    W_MIRROR_GUEST=${_guest}

    # --- the guest, its type, its estate and its configuration ------------
    if [ "${_guest}" = "db01" ]; then
        W_GUESTTYPE=bhyve
        mkdir -p "${_wd}/vm/db01"
        w_rcconf db01 > "${_wd}/vm/db01/rc.conf_db01"
    else
        W_GUESTTYPE=jail
        mkdir -p "${_wd}/jails-system/${_guest}"
        # sysdir=absent is a JAIL on real CBSD: its configuration lives outside
        # its own dataset, so it did not travel with the data and has to come
        # out of the dead node's configuration mirror instead (D-82).
        if [ "${_sysdir}" = "present" ]; then
            w_rcconf "${_guest}" \
                > "${_wd}/jails-system/${_guest}/rc.conf_${_guest}"
        fi
        # sysdir=stale is THE FLEET (D-187): a jails-system/<guest> directory
        # already on the survivor -- the platform keeps one per cluster guest
        # on every node -- holding a readable rc.conf that is WRONG (an older
        # data path) and a local.sqlite the platform cannot read. Readable is
        # not travelled; the mirror must be written over it.
        if [ "${_sysdir}" = "stale" ]; then
            w_rcconf "${_guest}" | sed -e "s|^data=.*|data=\"${_wd}/vm/${_guest}-STALE\";|" \
                > "${_wd}/jails-system/${_guest}/rc.conf_${_guest}"
            printf 'not a database\n' > "${_wd}/jails-system/${_guest}/local.sqlite"
        fi
    fi

    # WHAT THE PLATFORM SAYS AFTERWARDS. A guest registered from a
    # configuration naming a data path is a guest the platform then reports at
    # that path, and rung 6 checks its own work against exactly that
    # (D-181). The mock's world has one layout per type and no mount table, so
    # a row whose guest lives anywhere else says so here -- and `disagree` is
    # the row that proves the check can still fire.
    case "${_platform}" in
        agree)
            [ -n "${W_DATAPATH}" ] &&
                printf 'adapter_guest_data_path %s\tok\t%s\n' \
                    "${_guest}" "${W_DATAPATH}" >> "${SEANCE_MOCK_SCRIPT}"
            ;;
        disagree)
            printf 'adapter_guest_data_path %s\tok\t%s\n' \
                "${_guest}" "${_wd}/vm/${_guest}" >> "${SEANCE_MOCK_SCRIPT}"
            ;;
        silent)
            printf 'adapter_guest_data_path %s\tfail\tthis platform records no data path\n' \
                "${_guest}" >> "${SEANCE_MOCK_SCRIPT}"
            ;;
        *) t_diag "world_build: unknown platform: ${_platform}"; return 2 ;;
    esac

    # The configuration mirror sits in the standby tree beside the guests. It
    # is in the estate listing on purpose: rung 5 has to walk past it, and a
    # promotion of seance's own bookkeeping is the failure this row exists to
    # make impossible.
    case "${_replica}" in
        named|fleetshape|unnamed) W_REPLICA=${_replica} ;;
        *) t_diag "world_build: unknown replica shape: ${_replica}"; return 2 ;;
    esac

    case "${W_REPLICA}" in
        fleetshape) W_REPLICA_BASE="${_guest}-data" ;;
        *)          W_REPLICA_BASE="${_guest}" ;;
    esac

    W_GUESTROOT="pool0/bravo/standby/alpha/${W_REPLICA_BASE}"

    W_ESTATE="pool0/bravo/standby/alpha/${W_REPLICA_BASE}
pool0/bravo/standby/alpha/${REPL_SYS_GUEST}"

    # --- the replica's lineage --------------------------------------------
    W_TREE=${_tree}
    W_LINEAGE=${_lineage}

    SEANCE_MOCK_LINEAGE_NODE=alpha
    SEANCE_MOCK_LINEAGE_N=3
    case "${_lineage}" in
        fresh)  _lnow=$(( NOW - 60 )) ;;
        stale)  _lnow=$(( NOW - 4000 )) ;;
        skew)   _lnow=$(( NOW + 600 )) ;;
        absent) _lnow=${NOW}; SEANCE_MOCK_LINEAGE_NODE=bravo ;;
        empty0)
            _lnow=${NOW}
            ;;
        *) t_diag "world_build: unknown lineage: ${_lineage}"; return 2 ;;
    esac
    SEANCE_MOCK_LINEAGE_NOW=${_lnow}
    export SEANCE_MOCK_LINEAGE_NODE SEANCE_MOCK_LINEAGE_NOW SEANCE_MOCK_LINEAGE_N

    # --- the automatic path -----------------------------------------------
    #
    # The debounce wait is real on this path and is 45 s by default, so the
    # sleep is injected -- the row still takes the wait, still re-reads CARP
    # afterwards, and costs nothing. What is NOT faked is the re-check itself:
    # the mock adapter answers adapter_carp_state, and what it answers is the
    # difference between a death and a flapping link.
    PROMOTE_AUTO=${_auto}
    PROMOTE_DEBOUNCE_REQUIRED=0

    if [ "${_auto}" = "1" ]; then
        SEANCE_DEBOUNCE_SLEEP_CMD="${SHIM}/fakesleep"
        export SEANCE_DEBOUNCE_SLEEP_CMD
        printf 'adapter_carp_state 1\t%s\t%s\n' ok "${_carp}" \
            >> "${SEANCE_MOCK_SCRIPT}"
    else
        unset SEANCE_DEBOUNCE_SLEEP_CMD
    fi
    SEANCE_ZFS_LIST_CMD=mock_zfs_list
    export SEANCE_ZFS_LIST_CMD

    # --- who answers -------------------------------------------------------
    WORLD_SSH_ALIVE=""
    WORLD_PING_ALIVE=""

    if [ "${_reach}" -ge 1 ]; then
        WORLD_SSH_ALIVE="${WORLD_SSH_ALIVE} charlie-mgmt.example.net"
    fi
    if [ "${_reach}" -ge 2 ]; then
        WORLD_SSH_ALIVE="${WORLD_SSH_ALIVE} delta-mgmt.example.net"
    fi

    case "${_dead}" in
        no)   ;;
        ping) WORLD_PING_ALIVE="alpha-mgmt.example.net" ;;
        ssh)  WORLD_SSH_ALIVE="${WORLD_SSH_ALIVE} alpha-mgmt.example.net" ;;
        *) t_diag "world_build: unknown dead: ${_dead}"; return 2 ;;
    esac
    WORLD_SSH_MUTE=""
    if [ "${_peermute}" != "-" ]; then
        WORLD_SSH_MUTE="${_peermute}-mgmt.example.net"
    fi
    export WORLD_SSH_ALIVE WORLD_PING_ALIVE WORLD_SSH_MUTE

    printf '%s\n' "${SEANCE_MOCK_KERNEL}" > "${ROWDIR}/kernel.charlie-mgmt.example.net"
    printf '%s\n' "${SEANCE_MOCK_KERNEL}" > "${ROWDIR}/kernel.delta-mgmt.example.net"
    if [ "${_kernel}" = "differs" ]; then
        printf '14.2-RELEASE-p1\n' > "${ROWDIR}/kernel.charlie-mgmt.example.net"
    fi

    if [ "${_claim}" != "-" ]; then
        printf 'placement\t%s\talpha\n' "${_guest}" \
            > "${ROWDIR}/claims.${_claim}-mgmt.example.net"
    fi

    # --- the notification command ------------------------------------------
    case "${_notify}" in
        none) ;;
        ok)
            # shellcheck disable=SC2016
            #   The single quotes are the point: "$1" is source text of the
            #   script being written, not an expansion for this shell.
            printf '#!/bin/sh\ncat > "%s/notify.body"\nprintf "%%s\\n" "$1" > "%s/notify.subject"\nprintf -- "--- %%s\\n" "$1" >> "%s/notify.log"\ncat "%s/notify.body" >> "%s/notify.log"\nexit 0\n' \
                "${ROWDIR}" "${ROWDIR}" "${ROWDIR}" "${ROWDIR}" "${ROWDIR}" \
                > "${ROWDIR}/notify"
            chmod 0755 "${ROWDIR}/notify"
            ;;
        missing) ;;
        crash)
            printf '#!/bin/sh\ncat > /dev/null\nexit 3\n' > "${ROWDIR}/notify"
            chmod 0755 "${ROWDIR}/notify"
            ;;
        hang)
            printf '#!/bin/sh\nsleep 30\n' > "${ROWDIR}/notify"
            chmod 0755 "${ROWDIR}/notify"
            ;;
        *) t_diag "world_build: unknown notify: ${_notify}"; return 2 ;;
    esac

    # --- the configuration --------------------------------------------------
    _conf="${ROWDIR}/seance.conf"
    {
        printf 'cadence=900\n'
        printf 'fence_timeout=1\n'
        printf 'standby_root=pool0/%%n/standby\n'
        case "${_notify}" in
            none) ;;
            missing) printf 'notify_cmd=%s/no-such-notifier\n' "${ROWDIR}" ;;
            *) printf 'notify_cmd=%s/notify\n' "${ROWDIR}" ;;
        esac

        printf 'carp_interface=vtnet0\n'
        printf 'auto=%s\n' "${_fleetauto}"

        printf 'node_alpha_nodename=alpha\n'
        printf 'node_alpha_mgmt=alpha-mgmt.example.net\n'
        if [ "${_vhid}" = "yes" ]; then
            printf 'node_alpha_vhid=1\n'
            printf 'node_alpha_vhid_ip=192.0.2.101/32\n'
        fi

        # Whose guests alpha's are, when alpha is gone. The default is the
        # fleet every other row assumes -- this node first. The others are
        # configurations that pass `config --check` and put this node
        # somewhere else in the queue (battery a).
        case "${_succ}" in
            default)
                printf 'node_alpha_heir=bravo\n'
                [ "${_nodes}" -ge 3 ] && printf 'node_alpha_heir2=charlie\n'
                ;;
            h2self)
                # The first heir is somewhere else and this node is second.
                printf 'node_alpha_heir=charlie\n'
                printf 'node_alpha_heir2=bravo\n'
                ;;
            none)
                # alpha has no succession at all: legal, checks clean, and
                # means nothing here may inherit anything of alpha's.
                ;;
            *)
                t_diag "world_build: unknown succ: ${_succ}"
                return 2
                ;;
        esac
        case "${_fence}" in
            none) ;;
            targetless)
                # A driver named with nothing to name to it. conf_check
                # requires a driver for every target and not the reverse, so
                # this is a configuration that passes --check.
                printf 'node_alpha_fence_driver=mock\n'
                ;;
            missing)
                printf 'node_alpha_fence_driver=nosuchdriver\n'
                printf 'node_alpha_fence_target=alpha\n'
                ;;
            *)
                printf 'node_alpha_fence_driver=mock\n'
                printf 'node_alpha_fence_target=alpha\n'
                ;;
        esac

        printf 'node_bravo_nodename=bravo\n'
        printf 'node_bravo_mgmt=bravo-mgmt.example.net\n'
        printf 'node_bravo_heir=alpha\n'
        printf 'node_bravo_vhid=2\n'
        printf 'node_bravo_vhid_ip=192.0.2.102/32\n'
        [ "${_armed}" = "yes" ] && printf 'node_bravo_auto_promote=alpha\n'

        # A per-guest heir override (D-29): the guest's succession, not the
        # node's. It is what makes the woken node NOT the guest's actor, which
        # is the whole of D-130.
        [ "${_override}" != "-" ] &&
            printf 'guest_%s_heir=%s\n' "${_guest}" "${_override}"

        _n=3
        while [ "${_n}" -le "${_nodes}" ]; do
            case "${_n}" in
                3)
                    printf 'node_charlie_nodename=charlie\n'
                    printf 'node_charlie_mgmt=charlie-mgmt.example.net\n'
                    ;;
                4)
                    printf 'node_delta_nodename=delta\n'
                    printf 'node_delta_mgmt=delta-mgmt.example.net\n'
                    ;;
            esac
            _n=$(( _n + 1 ))
        done
    } > "${_conf}"

    case "${_fence}" in
        none|missing|targetless|off) ;;
        *) FENCE_MOCK_MODE=${_fence} ;;
    esac

    SEANCE_CONF=${_conf}
    export SEANCE_CONF

    conf_load "${_conf}" || return 2

    return 0
}

# ---------------------------------------------------------------------------
# Running one row, and judging it
# ---------------------------------------------------------------------------

ROW_EXIT=0
ROW_OUT=""

# row_run <id> <world> <force>
row_run()
{
    local _id _world _force

    _id=$1
    _world=$2
    _force=$3

    world_build "${_world}" || return 2

    ROW_OUT="${ROWDIR}/out"

    PROMOTE_FORCE=""
    case "${_force}" in
        -)   ;;
        all) promote_parse_force "" || return 2 ;;
        *)   promote_parse_force "${_force}" || return 2 ;;
    esac

    promote_run alpha "" > "${ROW_OUT}" 2>&1
    ROW_EXIT=$?

    return 0
}

# row_check <id> <got-disp> <got-ev> <got-stop> <got-exit>
#           <want-disp> <want-ev> <want-stop> <want-exit>
#
# rc 0 when every field matches; otherwise it diagnoses each mismatch and
# returns 1. Factored out so that the comparison itself can be mutation-checked
# below: a table driver that would pass whatever the table said is a table
# nobody is reading.
row_check()
{
    local _id _gd _ge _gs _gx _wd _we _ws _wx _rc

    _id=$1; _gd=$2; _ge=$3; _gs=$4; _gx=$5
    _wd=$6; _we=$7; _ws=$8; _wx=$9

    _rc=0

    [ "${_gd}" = "${_wd}" ] || {
        t_diag "${_id}: disposition got [${_gd}] want [${_wd}]"
        _rc=1
    }
    [ "${_ge}" = "${_we}" ] || {
        t_diag "${_id}: evidence got [${_ge}] want [${_we}]"
        _rc=1
    }
    [ "${_gs}" = "${_ws}" ] || {
        t_diag "${_id}: stopped-rung got [${_gs}] want [${_ws}]"
        _rc=1
    }
    [ "${_gx}" = "${_wx}" ] || {
        t_diag "${_id}: exit got [${_gx}] want [${_wx}]"
        _rc=1
    }

    return "${_rc}"
}

# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------

rows()
{
    awk -F "${TAB}" '
        /^#/     { next }
        NF < 7   { next }
        $1 == "id" { next }
        { print }
    ' "${TABLE}"
}

ROWS=$( rows )
NROWS=$( printf '%s\n' "${ROWS}" | awk 'NF > 0 { n++ } END { print n + 0 }' )

if [ "${NROWS}" -eq 0 ]; then
    t_plan 1
    t_not_ok "the ladder table has rows"
    t_done
fi

# One assertion per row, plus the twenty-five named assertions below. A table
# with no rows would have produced a green run of nothing, which is why the
# count is derived from the table rather than written down.
t_plan $(( NROWS + 123 ))

SAVED=$( t_tmpdir )
AUTO_ROWS=""

OIFS=$IFS
IFS='
'
# shellcheck disable=SC2086
#   Deliberate word splitting on newline: one table row per element.
for row in ${ROWS}; do
    IFS=$OIFS

    id=$( printf '%s\n' "${row}" | cut -f 1 )
    world=$( printf '%s\n' "${row}" | cut -f 2 )
    force=$( printf '%s\n' "${row}" | cut -f 3 )
    want_disp=$( printf '%s\n' "${row}" | cut -f 4 )
    want_ev=$( printf '%s\n' "${row}" | cut -f 5 )
    want_stop=$( printf '%s\n' "${row}" | cut -f 6 )
    want_exit=$( printf '%s\n' "${row}" | cut -f 7 )

    want_ev=$( printf '%s' "${want_ev}" | sed -e "s|%OP%|${OP}|" )
    [ "${want_ev}" = "-" ] && want_ev=""
    [ "${want_stop}" = "-" ] && want_stop=""
    [ "${want_disp}" = "-" ] && want_disp=""

    if ! row_run "${id}" "${world}" "${force}"; then
        t_not_ok "${id}: the world could not be built"
        IFS='
'
        continue
    fi

    # Which rows were AUTOMATIC runs, read from the table rather than from the
    # row's name: the "no --auto run ever records a forced promotion" assertion
    # below is over the whole table, and a rule that depended on an id's
    # spelling would stop covering the next row somebody adds.
    case "${world}" in
        auto=1|auto=1\ *|*\ auto=1|*\ auto=1\ *) AUTO_ROWS="${AUTO_ROWS} ${id}" ;;
    esac

    cp "${ROW_OUT}" "${SAVED}/${id}.out"
    cp "${W_ZFSLOG}" "${SAVED}/${id}.zfs"
    [ -r "${SEANCE_MOCK_LOG}" ] && cp "${SEANCE_MOCK_LOG}" "${SAVED}/${id}.mock"
    [ -r "${FENCE_MOCK_LOG}" ] && cp "${FENCE_MOCK_LOG}" "${SAVED}/${id}.fence"
    [ -r "${ROWDIR}/logger.log" ] && cp "${ROWDIR}/logger.log" "${SAVED}/${id}.logger"
    [ -r "${ROWDIR}/notify.body" ] && cp "${ROWDIR}/notify.body" "${SAVED}/${id}.notify"
    [ -r "${ROWDIR}/notify.subject" ] &&
        cp "${ROWDIR}/notify.subject" "${SAVED}/${id}.notify.subject"
    [ -r "${ROWDIR}/notify.log" ] && cp "${ROWDIR}/notify.log" "${SAVED}/${id}.notify.log"
    [ -r "${SEANCE_STATE_DIR}/succession.log" ] &&
        cp "${SEANCE_STATE_DIR}/succession.log" "${SAVED}/${id}.succession"
    [ -r "${SEANCE_STATE_DIR}/placement" ] &&
        cp "${SEANCE_STATE_DIR}/placement" "${SAVED}/${id}.placement"

    if row_check "${id}" \
        "${PROMOTE_DISPOSITION}" "${PROMOTE_EVIDENCE}" \
        "${PROMOTE_STOPPED_RUNG}" "${ROW_EXIT}" \
        "${want_disp}" "${want_ev}" "${want_stop}" "${want_exit}"
    then
        t_ok "${id}: ${world} force=${force} -> ${want_disp}"
    else
        t_not_ok "${id}: ${world} force=${force} -> ${want_disp}"
        sed -e 's/^/# out: /' "${ROW_OUT}"
    fi

    IFS='
'
done
IFS=$OIFS

# ---------------------------------------------------------------------------
# --force skips EXACTLY the rungs it names, read from the rung lines
# ---------------------------------------------------------------------------

t_like "$( cat "${SAVED}/force-quorum-only.out" )" '^rung 2 quorum: forced' \
    "--force=quorum says so on the quorum rung"
t_unlike "$( cat "${SAVED}/force-quorum-only.out" )" '^rung 4 fence: forced' \
    "--force=quorum does not touch the fence rung"
t_like "$( cat "${SAVED}/fence-unknown-forced.out" )" '^rung 4 fence: forced' \
    "--force=fence says so on the fence rung"
t_unlike "$( cat "${SAVED}/fence-unknown-forced.out" )" '^rung 2 quorum: forced' \
    "--force=fence does not touch the quorum rung"

# ---------------------------------------------------------------------------
# The shape of a successful run
# ---------------------------------------------------------------------------

t_like "$( cat "${SAVED}/happy.out" )" '^rung 1 debounce: n/a \(manual\)' \
    "rung 1 reports n/a for a promotion a human typed"
t_like "$( cat "${SAVED}/happy.out" )" '^rung 7 post: ' \
    "rung 7 says what the next replication tick will do"
t_like "$( cat "${SAVED}/happy.out" )" 'RPO ' \
    "a promoted guest reports its RPO"
t_like "$( cat "${SAVED}/happy.out" )" '^  undo: ' \
    "every mutating step prints its undo"
t_like "$( cat "${SAVED}/happy.succession" )" \
    "^web01	alpha	bravo	[0-9]{8}T[0-9]{6}Z	fence:mock\$" \
    "the succession record is a TSV of guest, old home, new home, ts, evidence"
t_is "$( cat "${SAVED}/happy.placement" )" "web01	alpha" \
    "placement records the guest and the home it came from"
t_like "$( cat "${SAVED}/happy.zfs" )" \
    "^set mountpoint=.*/jails-data/web01-data pool0/bravo/standby/alpha/web01\$" \
    "the replica is mounted IN PLACE at the path the platform expects"
t_like "$( cat "${SAVED}/happy.zfs" )" '^mount pool0/bravo/standby/alpha/web01$' \
    "and it is mounted explicitly, because canmount stays noauto"

# ---------------------------------------------------------------------------
# The replica's identity (D-183)
#
# The fleet shape is the one that mattered: a replica called <guest>-data,
# because that is what CBSD called the source dataset. Deriving the guest's
# name from that basename names a guest that does not exist, and the ladder
# refused a correct promotion with the home node already down. These rows say
# the name is READ, and that a replica with no recorded name is refused BY
# DATASET rather than skipped or guessed at.
# ---------------------------------------------------------------------------

t_like "$( cat "${SAVED}/replica-fleetshape.out" )" \
    '^rung 5 lineage: pass .*estate of alpha .*: web01 ' \
    "a replica called web01-data is the guest web01, because the tick recorded it"
t_unlike "$( cat "${SAVED}/replica-fleetshape.out" )" 'web01-data:' \
    "and nothing downstream ever calls the guest by its dataset's name"
t_like "$( cat "${SAVED}/replica-fleetshape.out" )" \
    '^rung 6 promotion: pass .*promoting, alphabetically:  *web01 *$' \
    "so it is promoted under the name the platform knows it by"
t_like "$( cat "${SAVED}/replica-fleetshape.zfs" )" \
    "^set mountpoint=.*/jails-data/web01-data pool0/bravo/standby/alpha/web01-data\$" \
    "the ceremony mounts the dataset it really is, at the path the guest's own configuration named"
t_is "$( cat "${SAVED}/replica-fleetshape.placement" )" "web01	alpha" \
    "and the placement claim names the GUEST, which is what the boot gate reads"

t_like "$( cat "${SAVED}/replica-unnamed.out" )" \
    'pool0/bravo/standby/alpha/web01 carries no seance:guest property' \
    "a replica that records no guest name is refused by DATASET"
t_like "$( cat "${SAVED}/replica-unnamed.out" )" 'One replication tick on alpha records it' \
    "and the refusal names the remedy, which is a tick and never a hand-set property"
t_unlike "$( cat "${SAVED}/replica-unnamed.out" )" '^rung 6 promotion: pass' \
    "nothing is promoted under a guessed name"
t_like "$( cat "${SAVED}/replica-unnamed.out" )" \
    '^rung 6 promotion: n/a .*record no guest name, so they were not considered' \
    "and rung 6 says which replicas it could not consider -- silence would read as 'nothing here'"
t_unlike "$( cat "${SAVED}/replica-unnamed-forced.out" )" '^rung 6 promotion: pass' \
    "and --force does not make an unnameable replica promotable: it is not a rung"

# ---------------------------------------------------------------------------
# The driver environment seance promises a fence driver (D-53)
# ---------------------------------------------------------------------------

t_like "$( cat "${SAVED}/happy.fence" )" '^off alpha 1 .*/etc/seance-fence-ipmi\.conf$' \
    "the fence driver is invoked as 'off <target>' with SEANCE_FENCE_TIMEOUT and SEANCE_FENCE_IPMI_CONF exported"

# ---------------------------------------------------------------------------
# Nothing happens that should not
# ---------------------------------------------------------------------------

t_is "$( ls "${SAVED}/probes-ping.fence" 2>/dev/null )" "" \
    "a host that answered ping was never handed to the fence driver"
t_unlike "$( cat "${SAVED}/claim-by-peer.mock" )" 'adapter_guest_register' \
    "a guest another peer already claims is not registered here"
t_like "$( cat "${SAVED}/peer-cannot-report.out" )" \
    'living peer\(s\) charlie answered ssh but could not state their placement' \
    "a living peer that cannot say what it holds stops the promotion, and is named"
t_unlike "$( cat "${SAVED}/peer-cannot-report.mock" )" 'adapter_guest_register' \
    "and nothing is registered on that silence: it is not evidence of no claim"
t_unlike "$( cat "${SAVED}/lineage-stale.mock" )" 'adapter_guest_start' \
    "a stale replica is not started without --force"

# ---------------------------------------------------------------------------
# The notify contract
# ---------------------------------------------------------------------------

t_isnt "$( cat "${SAVED}/notify-none.logger" )" "" \
    "with no notify_cmd the notification still reaches syslog"

# ---------------------------------------------------------------------------
# The promotion point (D-85)
#
# A tick that died part way leaves one dataset of a guest ahead of the others.
# The instant to promote at is the newest one the WHOLE tree exists at, and
# anything ahead of it is rolled back -- loudly, because there is no undo.
# ---------------------------------------------------------------------------

AHEAD_TS=$( pol_epoch_to_ts $(( NOW - 60 + 900 )) )
POINT_TS=$( pol_epoch_to_ts $(( NOW - 60 )) )

t_like "$( cat "${SAVED}/tree-child-ahead.out" )" \
    "promotion point ${POINT_TS}" \
    "the promotion point is the instant the whole tree shares, not the newest anywhere"
t_like "$( cat "${SAVED}/tree-child-ahead.out" )" \
    '^  pool0/bravo/standby/alpha/web01/data is AHEAD of the promotion point' \
    "the dataset that ran ahead is named"
t_like "$( cat "${SAVED}/tree-child-ahead.out" )" \
    "    destroying pool0/bravo/standby/alpha/web01/data@seance-alpha-${AHEAD_TS}" \
    "and every snapshot the rollback destroys is printed, by name"
t_like "$( cat "${SAVED}/tree-child-ahead.out" )" \
    '^  undo: none -- zfs rollback -r destroys the snapshots after ' \
    "and the undo is stated as impossible rather than left out"
t_like "$( cat "${SAVED}/tree-child-ahead.zfs" )" \
    "^rollback pool0/bravo/standby/alpha/web01/data@seance-alpha-${POINT_TS}\$" \
    "the child is rolled back to the promotion point"
t_unlike "$( cat "${SAVED}/tree-child-ahead.zfs" )" \
    '^rollback pool0/bravo/standby/alpha/web01@' \
    "and the root, which was never ahead, is not touched"
t_like "$( cat "${SAVED}/tree-child-ahead.out" )" 'RPO ' \
    "the RPO is reported, and it is the common point's"

t_like "$( cat "${SAVED}/tree-child-foreign.out" )" \
    'no @seance-alpha-\* snapshot is present on EVERY dataset' \
    "a tree with a dataset carrying nothing of ours has no coherent instant"
t_unlike "$( cat "${SAVED}/tree-child-foreign.mock" )" 'adapter_guest_start' \
    "and it is not started -- an incoherent guest is aborted, and --force cannot reach it"
t_unlike "$( cat "${SAVED}/tree-child-foreign-forced.mock" )" 'adapter_guest_start' \
    "not even with every forceable rung named"

# ---------------------------------------------------------------------------
# WHERE THE REPLICA IS MOUNTED (D-178's open paragraph, closed by D-181)
#
# The path is the guest's own `data=`, read before anything is mounted out of
# whichever replica carries its configuration. These assertions are about the
# thing the disposition column cannot say: WHICH PATH, and out of WHICH FILE.
# ---------------------------------------------------------------------------

# The fleet, verbatim: a bhyve guest whose configuration puts it on the
# jail-shaped path. The convention for its type says ${workdir}/vm/<name>, and
# a ceremony that used the convention would mount the replica there, register
# the guest from an rc.conf naming somewhere else, and start nothing usable.
t_like "$( cat "${SAVED}/mount-fleet.out" )" \
    'db01: its own configuration in pool0/bravo/standby/alpha/seance-sys says data=.*/jails-data/db01-data' \
    "the mount path is READ out of the guest's own configuration, and the file it came from is named"
t_like "$( cat "${SAVED}/mount-fleet.zfs" )" \
    "^set mountpoint=.*/jails-data/db01-data pool0/bravo/standby/alpha/db01\$" \
    "so a VM on the jail layout is mounted where its own configuration says"
t_unlike "$( cat "${SAVED}/mount-fleet.zfs" )" \
    "^set mountpoint=.*/vm/db01 pool0/bravo/standby/alpha/db01\$" \
    "and NOT at the path this platform's creation convention for a VM would have named"
t_like "$( cat "${SAVED}/mount-fleet.out" )" \
    'db01: the platform looks for its data at .*/jails-data/db01-data, which is where its replica is mounted' \
    "and the platform, asked after the registration, agrees about the path"

# The other half of the same fact: the configuration that travelled inside the
# guest's own replica is the one that is read, and the ceremony says so.
t_like "$( cat "${SAVED}/mount-travels.out" )" \
    'web01: its own configuration in pool0/bravo/standby/alpha/web01 says data=' \
    "a configuration that travelled inside the guest's own replica is read out of THAT"
t_like "$( cat "${SAVED}/mount-travels.zfs" )" \
    '^mount-ro pool0/bravo/standby/alpha/web01$' \
    "which means the replica itself is borrowed read-only, before the ceremony mounts it"
t_like "$( cat "${SAVED}/mount-travels.zfs" )" \
    '^inherit mountpoint pool0/bravo/standby/alpha/web01$' \
    "and given back afterwards, so the borrow leaves nothing behind"

# A configuration that states no data path at all: the LAST RESORT, announced.
t_like "$( cat "${SAVED}/mount-zero.out" )" \
    'states no data path .the platform.s schema default is "0"., so the LAST RESORT is used' \
    "a guest whose configuration states no data path falls back to the convention, and the note says so"
t_like "$( cat "${SAVED}/mount-zero.zfs" )" \
    "^set mountpoint=.*/jails-data/web01-data pool0/bravo/standby/alpha/web01\$" \
    "and the fallback is this platform's own answer for the type"

# A configuration that names something a replica cannot be mounted at is a
# REFUSAL. The difference from "states none" is the whole of it: seance knows
# the answer is wrong rather than missing, and a convention would paper over it.
t_like "$( cat "${SAVED}/mount-unusable.out" )" \
    'names a data path this node will not mount a replica at' \
    "a relative data path stops the promotion by name"
# The scratch borrow DOES set a mountpoint on the replica -- read-only, at a
# path under the run's own temporary directory -- so what this asserts is that
# nothing was pointed at the guest's FINAL path, which is the mount that would
# have mattered.
t_unlike "$( cat "${SAVED}/mount-unusable.zfs" )" \
    '^set mountpoint=.*/jails-data/web01-data pool0/bravo/standby/alpha/web01$' \
    "and nothing is mounted at the guest's final path"
t_unlike "$( cat "${SAVED}/mount-unusable.zfs" )" \
    '^mount pool0/bravo/standby/alpha/web01$' \
    "and the replica is never mounted read-write at all"
t_unlike "$( cat "${SAVED}/mount-unusable.mock" )" 'adapter_guest_register' \
    "and nothing is registered"
t_unlike "$( cat "${SAVED}/mount-unusable.mock" )" 'adapter_guest_start' \
    "and nothing is started"

# THE CHECK'S OWN FALSIFIABILITY. The platform is made to report the guest's
# data somewhere else once it is registered; the promotion must stop THERE,
# with the guest registered and not started, rather than starting it over a
# directory that is not its own.
t_like "$( cat "${SAVED}/mount-platform-disagrees.out" )" \
    'it is registered here and the platform looks for its data at .*/vm/db01, while its replica is mounted at .*/jails-data/db01-data' \
    "a platform that looks somewhere else stops the promotion, naming both paths"
t_like "$( cat "${SAVED}/mount-platform-disagrees.mock" )" 'adapter_guest_register' \
    "after the registration, which is where the disagreement becomes visible"
t_unlike "$( cat "${SAVED}/mount-platform-disagrees.mock" )" 'adapter_guest_start' \
    "and the guest is NOT started"

# And a platform that can say NOTHING about a guest it has just registered is
# not being quiet: it is saying the guest is not one of ours (D-184). On the
# fleet that was a registration still carrying the dead node's nodename -- the
# row came back as another node's, the enumerator skipped it as "not local to
# this node", and the start that followed failed with "no such guest" about a
# guest whose datasets were mounted underneath it. This row used to assert that
# the promotion STANDS, which is the assertion that let it walk into that.
t_like "$( cat "${SAVED}/mount-platform-silent.out" )" \
    'reports nothing about it -- not even where its data is' \
    "a platform with nothing to say about a guest it just registered is a STOP"
t_like "$( cat "${SAVED}/mount-platform-silent.out" )" \
    'NOTHING HAS BEEN STARTED' \
    "and the stop says so, with the undo lines above it"
t_unlike "$( cat "${SAVED}/mount-platform-silent.out" )" '^  started ' \
    "nothing was started on a guest the platform will not claim"

# ---------------------------------------------------------------------------
# A stale sysdir on the survivor is NOT the guest's configuration (D-187)
#
# drill-guest attempt 3: the survivor held the platform's own months-old
# jails-system/<guest> directory, rc.conf readable, local.sqlite from an older
# schema. Rung 6 read "readable" as "travelled", never restored the mirror,
# registered the guest against a database the platform could not read, and
# the platform reported nothing about a guest whose datasets were mounted
# underneath it.
# ---------------------------------------------------------------------------

t_like "$( cat "${SAVED}/sysdir-stale.out" )" \
    'did not travel inside its own datasets; restoring it from alpha.s configuration mirror' \
    "a readable rc.conf in a sysdir that does not resolve into the replica is NOT travelled"
t_like "$( cat "${SAVED}/sysdir-stale.out" )" \
    'already existed here \(the platform.s own, stale copy\); backed up to' \
    "the survivor's own copy is backed up before the mirror overwrites it"
t_like "$( cat "${SAVED}/sysdir-stale.out" )" \
    '^  undo: find .*/jails-system/web01 -mindepth 1 -delete; cp -a .*/sysdir-backup/web01\.' \
    "and the undo line puts that copy back rather than deleting a directory the platform made"
t_unlike "$( cat "${SAVED}/sysdir-stale.out" )" 'STALE' \
    "nothing downstream ever saw the stale data path"
t_is "$( cat "${SAVED}/sysdir-stale.placement" )" "web01	alpha" \
    "and the guest is promoted from the mirror's configuration"

t_like "$( cat "${SAVED}/sysdir-stale-mirror-absent.out" )" \
    'its configuration is not here' \
    "with no mirror, a stale local copy is a REFUSAL, not a fallback: it is the survivor's, not the guest's"

# ---------------------------------------------------------------------------
# The configuration mirror (D-82)
# ---------------------------------------------------------------------------

t_unlike "$( cat "${SAVED}/happy.out" )" "${REPL_SYS_GUEST}: " \
    "the configuration mirror is in the standby tree and is NOT promoted as a guest"
t_like "$( cat "${SAVED}/happy.out" )" '^promote: 1 of 1 guest\(s\) promoted from alpha' \
    "so the estate is the guests, and the mirror beside them is not counted as one"

t_like "$( cat "${SAVED}/sysdir-from-mirror.out" )" \
    'restored web01.s configuration into .*/jails-system/web01' \
    "a guest whose configuration did not travel is restored from the mirror"
t_like "$( cat "${SAVED}/sysdir-from-mirror.zfs" )" \
    "^mount-ro pool0/bravo/standby/alpha/${REPL_SYS_GUEST}\$" \
    "and the mirror is mounted READ-ONLY to do it"
t_like "$( cat "${SAVED}/sysdir-from-mirror.zfs" )" \
    "^inherit mountpoint pool0/bravo/standby/alpha/${REPL_SYS_GUEST}\$" \
    "and put back to where it was afterwards, mounted nowhere"

t_like "$( cat "${SAVED}/sysdir-mirror-absent.out" )" \
    'no configuration mirror at pool0/bravo/standby/alpha/seance-sys' \
    "a guest whose configuration is nowhere is refused, and the reason is named"
t_unlike "$( cat "${SAVED}/sysdir-mirror-absent.mock" )" 'adapter_guest_start' \
    "and it is NOT started: a guest registered from a configuration seance guessed is worse than one that did not come back"

# ---------------------------------------------------------------------------
# The automatic path
#
# Two things are being pinned here that the table's four columns cannot say.
# The first is that rung 1 became REAL: the wait is taken and the CARP state is
# re-read afterwards, and a node that is no longer MASTER stops. The second is
# that the automatic path cannot be forced -- not that it declines to, but that
# the two flags are not expressible together at all.
# ---------------------------------------------------------------------------

t_like "$( cat "${SAVED}/auto-happy.out" )" '^rung 0 arming: pass' \
    "the automatic path checks that it is armed before it does anything else"
t_like "$( cat "${SAVED}/auto-happy.out" )" \
    '^rung 1 debounce: pass — waited 45s and this node is still MASTER for vhid 1' \
    "and rung 1 waits and then re-reads CARP, rather than reporting n/a"
t_is "$( cat "${SLEEPLOG}" | LC_ALL=C sort -u )" "45" \
    "every automatic row really took the wait, for the configured number of seconds"
t_unlike "$( cat "${SAVED}/auto-happy.out" )" 'forced' \
    "nothing on the automatic path is forced, because nothing on it can be"

t_like "$( cat "${SAVED}/auto-transient.out" )" '^rung 1 debounce: abort — TRANSIENT MASTER' \
    "a node that is BACKUP again after the wait stops at rung 1"
t_unlike "$( cat "${SAVED}/auto-transient.mock" )" 'adapter_guest_register' \
    "and registers nothing: the link flapped, the node did not die"
t_unlike "$( cat "${SAVED}/auto-transient.mock" )" 'adapter_guest_start' \
    "and starts nothing"
t_is "$( ls "${SAVED}/auto-transient.fence" 2>/dev/null )" "" \
    "and nothing was handed to the fence driver -- rung 1 is before rung 4"

t_like "$( cat "${SAVED}/auto-fleet-off.out" )" \
    '^rung 0 arming: abort — --auto, but the fleet key auto is 0' \
    "auto=0 disarms the whole fleet whatever a node's own auto_promote says"
t_is "$( ls "${SAVED}/auto-fleet-off.fence" 2>/dev/null )" "" \
    "and a disarmed node fences nothing"
t_like "$( cat "${SAVED}/auto-not-armed.out" )" \
    '^rung 0 arming: abort — --auto, but node_bravo_auto_promote is ""' \
    "and a node whose own list does not name the corpse is disarmed too"
t_is "$( cat "${SAVED}/auto-fleet-off.zfs" )" "" \
    "a run stopped at rung 0 touches no dataset at all"

t_like "$( cat "${SAVED}/auto-force-refused.out" )" \
    '^promote: FAIL — --force may not be combined with --auto' \
    "--auto and --force together are a usage error, not a preference"
t_is "$( ls "${SAVED}/auto-force-refused.fence" 2>/dev/null )" "" \
    "and the refusal happens before anything is fenced"

t_like "$( cat "${SAVED}/auto-no-vhid.out" )" \
    'there is no vhid to re-check' \
    "an armed node whose corpse has no vhid cannot re-check, so it stops"

# The M3 gate: rungs 1-4 must ALL be green on the automatic path (design §7),
# which is true here by construction rather than by inspection -- every one of
# them stops the run, and none of them can be forced past.
for row in auto-transient auto-probes auto-fence-unknown auto-quorum-n2; do
    t_unlike "$( cat "${SAVED}/${row}.mock" )" 'adapter_guest_start' \
        "${row}: a rung 1-4 that is not green starts nothing"
done

# ---------------------------------------------------------------------------
# A per-guest override the automatic path cannot act on (D-129, D-130)
#
# CARP hands the dead node's vhid to ONE node and rung 1 has just confirmed it
# is this one; every other participant is BACKUP and its own --auto run stops at
# rung 1. So a guest whose per-guest succession names somebody else as its actor
# is a guest nothing will promote. Before D-130 that was a stand-down, which the
# automatic path does not page for, and the guest stayed down in silence -- the
# outcome D-129 recorded and this pair of rows now pins.
#
# The manual row is here for the same reason: what changed is the AUTOMATIC
# path, and a stand-down a human is reading is still a stand-down.
# ---------------------------------------------------------------------------

t_like "$( cat "${SAVED}/auto-override-deferred.out" )" \
    '^  web01: deferred -- succession is charlie, and this node is not the actor for it' \
    "an automatic run defers a guest whose actor is another node"
t_like "$( cat "${SAVED}/auto-override-deferred.out" )" \
    'run "seance promote alpha --guest web01" on charlie' \
    "and prints the exact command, and the node that has to run it"
t_like "$( cat "${SAVED}/auto-override-deferred.out" )" \
    '^deferred — no automation will promote these' \
    "the deferrals are collected before the verdict line, which is still last"
t_like "$( cat "${SAVED}/auto-override-deferred.out" )" \
    '^promote: 0 of 1 guest\(s\) promoted from alpha.*disposition deferred$' \
    "and the verdict line counts them as deferred rather than as stood down"
t_like "$( cat "${SAVED}/auto-override-deferred.notify" )" \
    'seance promote alpha --guest web01   \(on charlie\)' \
    "the automatic run PAGES, with the command in the body: this is D-130's point"
t_like "$( cat "${SAVED}/auto-override-deferred.notify.subject" )" \
    'automatic promotion of alpha stopped \(deferred\)' \
    "and the subject says which node's succession stopped"
t_unlike "$( cat "${SAVED}/auto-override-deferred.mock" )" 'adapter_guest_start' \
    "a deferred guest is not started here: deferring is standing down, loudly"

t_like "$( cat "${SAVED}/override-manual.out" )" \
    '^  web01: stand-down -- succession is charlie, and this node is not the actor for it' \
    "a MANUAL run still stands down, because a human is reading the line"
t_is "$( ls "${SAVED}/override-manual.notify" 2>/dev/null )" "" \
    "and does not page: the page is what the automatic path has instead of a reader"

# ---------------------------------------------------------------------------
# THE RECORDS AN AUTOMATIC RUN LEAVES, and the pages it sends
#
# `--force` and `--auto` are not expressible together (D-119), so no automatic
# run can record a forced promotion -- but "cannot be typed" and "never
# happens" are different sentences, and the one that matters to the person
# reading succession.log a week later is the second. It is asserted here over
# the WHOLE TABLE rather than for one row: every automatic run that recorded
# anything recorded a fence, by the driver's name.
#
# The pages are the other half. A run that stops has a rung to page for it
# (D-122); one that stops at rung 0 does not, and one that finishes has nothing
# to say. Counted from the notification log, because "it sent one" and "it sent
# two" are the same last-message-wins file otherwise.
# ---------------------------------------------------------------------------

AUTO_RECORDS=0
AUTO_FORCED=""
for id in ${AUTO_ROWS}; do
    [ -r "${SAVED}/${id}.succession" ] || continue
    while IFS= read -r line || [ -n "${line}" ]; do
        [ -n "${line}" ] || continue
        AUTO_RECORDS=$(( AUTO_RECORDS + 1 ))
        ev=$( printf '%s\n' "${line}" | cut -f 5 )
        case "${ev}" in
            fence:*) ;;
            *) AUTO_FORCED="${AUTO_FORCED} ${id}:${ev}" ;;
        esac
    done < "${SAVED}/${id}.succession"
done

t_rc 0 "the automatic rows of the table did record promotions (${AUTO_RECORDS} of them)" \
    -- test "${AUTO_RECORDS}" -gt 0
t_is "${AUTO_FORCED}" "" \
    "and every one of them is evidence fence:<driver> -- an --auto run can never record force:*"

# The negative control, so that the rule above is falsifiable: a MANUAL forced
# promotion does record the operator, in the same column, read the same way.
t_like "$( cat "${SAVED}/fence-unknown-forced.succession" )" \
    "^web01	alpha	bravo	[0-9]{8}T[0-9]{6}Z	force:${OP}\$" \
    "a manual --force=fence records force:<operator>, which is what makes the rule above measurable"

t_like "$( cat "${SAVED}/auto-happy.succession" )" \
    "^web01	alpha	bravo	[0-9]{8}T[0-9]{6}Z	fence:mock\$" \
    "an automatic promotion's record names the fence driver that made it safe"
t_is "$( cat "${SAVED}/auto-happy.placement" )" "web01	alpha" \
    "and the placement claim it leaves is the one the boot gate reads"

# A run that stopped before rung 6 claims nothing: a placement record is the
# statement "this guest is running here", and it was not.
t_is "$( ls "${SAVED}/auto-not-armed.placement" 2>/dev/null )" "" \
    "a run stopped at rung 0 leaves no placement claim"
t_is "$( ls "${SAVED}/auto-fence-unknown.placement" 2>/dev/null )" "" \
    "and neither does one stopped at the fence"

# --- the pages -------------------------------------------------------------

t_is "$( ls "${SAVED}/auto-happy-notify.notify.log" 2>/dev/null )" "" \
    "an automatic run that promoted everything pages nobody: there is nothing to say"

t_is "$( awk '/^--- /{ n++ } END { print n + 0 }' \
    "${SAVED}/auto-not-armed-notify.notify.log" )" "1" \
    "a run stopped at rung 0 sends exactly one page -- no rung sent one for it"
t_like "$( cat "${SAVED}/auto-not-armed-notify.notify.log" )" \
    'automatic promotion of alpha stopped \(abort\)' \
    "and the subject says the automatic promotion stopped"
t_like "$( cat "${SAVED}/auto-not-armed-notify.notify.log" )" \
    'Nothing further will happen without a human' \
    "and the body ends by saying so"
t_is "$( ls "${SAVED}/auto-not-armed-notify.fence" 2>/dev/null )" "" \
    "a run that stopped at arming fenced nothing"

t_is "$( awk '/^--- /{ n++ } END { print n + 0 }' \
    "${SAVED}/auto-fence-unknown-notify.notify.log" )" "1" \
    "a run the FENCE stopped sends exactly one page too: the rung's, not a second summary (D-122)"
t_unlike "$( cat "${SAVED}/auto-fence-unknown-notify.notify.log" )" \
    'automatic promotion of alpha stopped' \
    "and it is the rung's page, not the summary the rungs are excluded from"

t_is "$( awk '/^--- /{ n++ } END { print n + 0 }' \
    "${SAVED}/auto-override-deferred.notify.log" )" "1" \
    "and a run that promoted nothing because every guest was deferred pages once"

# ---------------------------------------------------------------------------
# --force's own vocabulary
# ---------------------------------------------------------------------------

PROMOTE_FORCE=""
t_rc 2 "--force=probes is a usage error: a live host is never fenced by force" \
    -- promote_parse_force probes
t_rc 2 "--force naming a rung that does not exist is a usage error" \
    -- promote_parse_force nosuchrung

PROMOTE_FORCE=""
promote_parse_force "" > /dev/null 2>&1
t_is "${PROMOTE_FORCE}" "quorum fence lineage kernel" \
    "a bare --force means every forceable rung and no others"

# ---------------------------------------------------------------------------
# Where a fence driver is looked for
# ---------------------------------------------------------------------------

drvroot=$( t_tmpdir )
mkdir -p "${drvroot}/drivers"
cp "${T_ROOT}/tests/drivers/fence_mock" "${drvroot}/drivers/fence_mock"
chmod 0755 "${drvroot}/drivers/fence_mock"

saved_root=${SEANCE_ROOT}
SEANCE_ROOT=${drvroot}
t_is "$( promote_fence_exe mock )" "${drvroot}/drivers/fence_mock" \
    "the module's own drivers/ directory wins over PATH"
SEANCE_ROOT=${saved_root}

# ---------------------------------------------------------------------------
# The debounce path exists and is injectable (M3 hangs CARP off it)
# ---------------------------------------------------------------------------

sleeplog=$( t_tmpdir )/slept
# shellcheck disable=SC2016
#   As above: "$1" is source text of the script being written.
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> "%s"\nexit 0\n' "${sleeplog}" \
    > "${SHIM}/oncesleep"
chmod 0755 "${SHIM}/oncesleep"

SEANCE_DEBOUNCE_SLEEP_CMD="${SHIM}/oncesleep"
export SEANCE_DEBOUNCE_SLEEP_CMD
t_rc 0 "promote_debounce_wait takes the injected wait" \
    -- promote_debounce_wait 45
t_is "$( cat "${sleeplog}" )" "45" \
    "and it waits for exactly the configured number of seconds"
unset SEANCE_DEBOUNCE_SLEEP_CMD

# ---------------------------------------------------------------------------
# The table driver's own mutation check
#
# A comparison that cannot fail makes every row above meaningless, so it is
# shown failing here, permanently, rather than once by hand.
# ---------------------------------------------------------------------------

t_rc 0 "row_check passes when every field matches" \
    -- row_check self proceed fence:mock "" 0 proceed fence:mock "" 0
t_rc 1 "row_check fails when ONE expected field is flipped" \
    -- row_check self proceed fence:mock "" 0 abort fence:mock "" 0

t_done
