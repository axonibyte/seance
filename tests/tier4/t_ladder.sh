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

cp "${T_ROOT}/tests/drivers/fence_mock" "${SHIM}/fence_mock"
chmod 0755 "${SHIM}/ssh" "${SHIM}/ping" "${SHIM}/logger" "${SHIM}/fence_mock"

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
W_SYSPATH=""

# shellcheck disable=SC2329
zfs_set()
{
    # Where the restore points the mirror is how this fixture learns which
    # scratch path to put a configuration in -- the same way the real pair of
    # commands works, with the code telling the pool rather than the other way
    # round.
    case "$2" in
        *"/${REPL_SYS_GUEST}")
            case "$1" in
                mountpoint=*) W_SYSPATH=${1#mountpoint=} ;;
            esac
            ;;
    esac
    printf 'set %s %s\n' "$1" "$2" >> "${W_ZFSLOG}"
}

# shellcheck disable=SC2329
zfs_exists()
{
    [ "${W_MIRROR}" != "absent" ]
}

# shellcheck disable=SC2329
zfs_mount_ro()
{
    printf 'mount-ro %s\n' "$1" >> "${W_ZFSLOG}"

    [ "${W_MIRROR}" = "ok" ] || return 0
    [ -n "${W_SYSPATH}" ] || return 0

    mkdir -p "${W_SYSPATH}/${W_MIRROR_GUEST}" || return 1
    printf 'name=%s\n' "${W_MIRROR_GUEST}" \
        > "${W_SYSPATH}/${W_MIRROR_GUEST}/rc.conf_${W_MIRROR_GUEST}"
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

# shellcheck disable=SC2329
zfs_mount()
{
    printf 'mount %s\n' "$1" >> "${W_ZFSLOG}"
}

# shellcheck disable=SC2329
zfs_mounted()
{
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

# shellcheck disable=SC2329
lineage_listing()
{
    local _want _root _base _ahead _ts

    _want=$1

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
    local _spec _kv _k _v
    local _nodes _reach _dead _fence _lineage _claim _peermute _kernel _guest _notify
    local _sysdir _mirror _tree
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

    FENCE_MOCK_LOG="${ROWDIR}/fence.log"
    FENCE_MOCK_MODE=off
    FENCE_MOCK_SLEEP=3
    export FENCE_MOCK_LOG FENCE_MOCK_MODE FENCE_MOCK_SLEEP

    # --- the guest, its type, its estate and its configuration ------------
    if [ "${_guest}" = "db01" ]; then
        W_GUESTTYPE=bhyve
        mkdir -p "${_wd}/vm/db01"
        printf 'name=db01\n' > "${_wd}/vm/db01/rc.conf_db01"
    else
        W_GUESTTYPE=jail
        mkdir -p "${_wd}/jails-system/${_guest}"
        # sysdir=absent is a JAIL on real CBSD: its configuration lives outside
        # its own dataset, so it did not travel with the data and has to come
        # out of the dead node's configuration mirror instead (D-82).
        if [ "${_sysdir}" = "present" ]; then
            printf 'name=%s\n' "${_guest}" \
                > "${_wd}/jails-system/${_guest}/rc.conf_${_guest}"
        fi
    fi

    W_MIRROR=${_mirror}
    W_MIRROR_GUEST=${_guest}
    W_SYSPATH=""

    # The configuration mirror sits in the standby tree beside the guests. It
    # is in the estate listing on purpose: rung 5 has to walk past it, and a
    # promotion of seance's own bookkeeping is the failure this row exists to
    # make impossible.
    W_GUESTROOT="pool0/bravo/standby/alpha/${_guest}"

    W_ESTATE="pool0/bravo/standby/alpha/${_guest}
pool0/bravo/standby/alpha/${REPL_SYS_GUEST}"

    # --- the replica's lineage --------------------------------------------
    W_TREE=${_tree}

    SEANCE_MOCK_LINEAGE_NODE=alpha
    SEANCE_MOCK_LINEAGE_N=3
    case "${_lineage}" in
        fresh)  _lnow=$(( NOW - 60 )) ;;
        stale)  _lnow=$(( NOW - 4000 )) ;;
        skew)   _lnow=$(( NOW + 600 )) ;;
        absent) _lnow=${NOW}; SEANCE_MOCK_LINEAGE_NODE=bravo ;;
        empty0)
            _lnow=${NOW}
            printf 'mock_zfs_list %s\tempty0\n' "${W_ESTATE}" \
                > "${SEANCE_MOCK_SCRIPT}"
            ;;
        *) t_diag "world_build: unknown lineage: ${_lineage}"; return 2 ;;
    esac
    SEANCE_MOCK_LINEAGE_NOW=${_lnow}
    export SEANCE_MOCK_LINEAGE_NODE SEANCE_MOCK_LINEAGE_NOW SEANCE_MOCK_LINEAGE_N
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
            printf '#!/bin/sh\ncat > "%s/notify.body"\nprintf "%%s\\n" "$1" > "%s/notify.subject"\nexit 0\n' \
                "${ROWDIR}" "${ROWDIR}" > "${ROWDIR}/notify"
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

        printf 'node_alpha_nodename=alpha\n'
        printf 'node_alpha_mgmt=alpha-mgmt.example.net\n'
        printf 'node_alpha_heir=bravo\n'
        [ "${_nodes}" -ge 3 ] && printf 'node_alpha_heir2=charlie\n'
        case "${_fence}" in
            none) ;;
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
        none|missing|off) ;;
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
t_plan $(( NROWS + 44 ))

SAVED=$( t_tmpdir )

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

    if ! row_run "${id}" "${world}" "${force}"; then
        t_not_ok "${id}: the world could not be built"
        IFS='
'
        continue
    fi

    cp "${ROW_OUT}" "${SAVED}/${id}.out"
    cp "${W_ZFSLOG}" "${SAVED}/${id}.zfs"
    [ -r "${SEANCE_MOCK_LOG}" ] && cp "${SEANCE_MOCK_LOG}" "${SAVED}/${id}.mock"
    [ -r "${FENCE_MOCK_LOG}" ] && cp "${FENCE_MOCK_LOG}" "${SAVED}/${id}.fence"
    [ -r "${ROWDIR}/logger.log" ] && cp "${ROWDIR}/logger.log" "${SAVED}/${id}.logger"
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
    > "${SHIM}/fakesleep"
chmod 0755 "${SHIM}/fakesleep"

SEANCE_DEBOUNCE_SLEEP_CMD="${SHIM}/fakesleep"
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
