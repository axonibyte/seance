#!/bin/sh
# Tier 6, stage 'substrate' -- the pseudo-cluster proves itself.
#
# Nothing of seance runs here. This stage asserts that the shape-A substrate
# (TESTING.md §1) is what the later stages are entitled to assume: three vnet
# jails on a private bridge, an ssh mesh including the guest host, a delegated
# ZFS subtree per node, ZFS send/recv over ssh *between jails* (the shape-A
# replication transport, proven without a replication engine), link isolation
# that leaves the jail alive, a node that can be stopped and restarted with
# its state intact, and a teardown that leaves the guest as it found it.
#
# It also records one informational probe -- whether CARP loads in the guest
# and can be configured inside a vnet jail -- because M3 needs the answer and
# this is the only session shape that can ask.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/stage.subr
. "${T_ROOT}/tests/cluster/lib/stage.subr"

stage_begin substrate

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the substrate stage builds jails and ZFS datasets; it needs root"
    echo "t_substrate: must run as root" >&2
    exit 2
fi

t_plan 40

# ---------------------------------------------------------------------------
# The harness hook the substrate's teardown rides on
#
# cluster_up arms cluster_down through t_at_exit, so a stage script that dies
# half way through still leaves the guest clean. That makes t_at_exit part of
# the substrate, and it is asserted here -- cheaply, before anything is built,
# so a broken hook is found before there is anything to leak.
# ---------------------------------------------------------------------------

INNER_OUT=""
INNER_RC=0

inner()
{
    local _dir

    _dir=$( t_tmpdir )

    {
        echo "#!/bin/sh"
        echo "set -u"
        echo ". \"${T_ROOT}/tests/lib/harness.subr\""
        printf '%s\n' "$1"
    } > "${_dir}/inner.sh"

    INNER_OUT=$( sh "${_dir}/inner.sh" 2>&1 )
    INNER_RC=$?
}

hookdir=$( t_tmpdir )

inner "t_plan 1
t_at_exit \"echo AT_EXIT_RAN\"
t_ok ok
t_done"
t_like "${INNER_OUT}" '^AT_EXIT_RAN$' "t_at_exit runs its command at exit"
t_is "${INNER_RC}" "0" "t_at_exit does not disturb a passing file's status"

inner "t_plan 1
t_at_exit \"echo FIRST >> ${hookdir}/order\"
t_at_exit \"echo SECOND >> ${hookdir}/order\"
t_ok ok
t_done"
t_is "$( tr '\n' ' ' < "${hookdir}/order" )" "SECOND FIRST " \
    "t_at_exit runs commands in reverse order of registration"

inner "t_plan 1
t_at_exit \"echo LATE >> ${hookdir}/late\"
t_is one two 'deliberate failure'
t_done"
t_isnt "${INNER_RC}" "0" "t_at_exit does not rescue a failing file's status"
t_is "$( cat "${hookdir}/late" 2>/dev/null )" "LATE" \
    "t_at_exit still runs when the file failed"

# ---------------------------------------------------------------------------
# Bring the cluster up
# ---------------------------------------------------------------------------

AK=/root/.ssh/authorized_keys

authkeys_fingerprint()
{
    if [ -r "${AK}" ]; then
        sha256 -q "${AK}"
    else
        echo ABSENT
    fi
}

ak_before=$( authkeys_fingerprint )

t_rc 0 "cluster_up 3 succeeds" -- cluster_up 3

# jail_names -- the node jails present, dying ones included.
#
# 'jls -d': a jail that has been removed but is still dying still holds its
# vnet interface and its mounts, and calling that "gone" is how a teardown
# comes to look clean while the guest is not.
jail_names()
{
    jls -d -h name 2>/dev/null | awk 'NR > 1 && $1 ~ /^sn-/ { print $1 }' \
        | sort | tr '\n' ' '
}

t_is "$( jail_names )" "sn-alpha sn-bravo sn-charlie " \
    "the three node jails are running"

NODE_OPTS=$( cluster_ssh_opts "$( cluster_node_key )" )

# node_ssh <from> <to> <cmd...> -- ssh between two nodes, by hostname, using
# the mesh key from inside the source jail.
#
# shellcheck disable=SC2329
#   Invoked indirectly, as the command t_rc runs after its '--'.
node_ssh()
{
    local _from _to

    _from=$1
    _to=$2
    shift 2

    # shellcheck disable=SC2086
    #   Deliberate word splitting: ${NODE_OPTS} is an ssh option list.
    #
    # </dev/null because ssh reads stdin and would otherwise consume this
    # test file's, which run.sh has pointed at whatever invoked it.
    cluster_exec "${_from}" ssh ${NODE_OPTS} "root@${_to}" "$@" < /dev/null
}

for from in alpha bravo charlie; do
    for to in alpha bravo charlie; do
        [ "${from}" = "${to}" ] && continue
        t_rc 0 "ssh ${from} -> ${to}" -- node_ssh "${from}" "${to}" true
    done
done

for from in alpha bravo charlie; do
    t_rc 0 "ssh ${from} -> host" -- node_ssh "${from}" host true
done

# ---------------------------------------------------------------------------
# Delegated ZFS, inside the jails
# ---------------------------------------------------------------------------

for node in alpha bravo charlie; do
    ds=$( cluster_dataset "${node}" )
    if cluster_exec "${node}" zfs create "${ds}/estate" &&
       cluster_exec "${node}" sh -c "echo ${node} > /seance/estate/who" &&
       cluster_exec "${node}" zfs snapshot "${ds}/estate@s1"; then
        t_ok "${node}: zfs create + write + snapshot inside the jail"
    else
        t_not_ok "${node}: zfs create + write + snapshot inside the jail"
        cluster_exec "${node}" zfs list -t all -r "${ds}" >&2
    fi
done

# ---------------------------------------------------------------------------
# The shape-A replication transport: zfs send | ssh peer zfs recv, jail to
# jail, with no seance anywhere near it.
#
# The pipeline's own status is ssh's, so the sender's status is captured to a
# file (lib/common.subr's RC-capture pattern) rather than inferred -- a send
# that died into a receive that succeeded is exactly the false pass this
# repository keeps finding.
# ---------------------------------------------------------------------------

alpha_ds=$( cluster_dataset alpha )
bravo_ds=$( cluster_dataset bravo )
alpha_root=$( cluster_root alpha )

cat > "${alpha_root}/tmp/replicate.sh" <<EOF
#!/bin/sh
set -u
rcf=/tmp/send.rc
( zfs send "${alpha_ds}/estate@s1"; echo \$? > "\${rcf}" ) |
    ssh ${NODE_OPTS} root@bravo zfs recv -F "${bravo_ds}/from-alpha"
recv_rc=\$?
send_rc=\$( cat "\${rcf}" )
echo "send_rc=\${send_rc} recv_rc=\${recv_rc}"
[ "\${send_rc}" -eq 0 ] || exit 1
[ "\${recv_rc}" -eq 0 ] || exit 1
exit 0
EOF
chmod 0755 "${alpha_root}/tmp/replicate.sh"

t_rc 0 "zfs send | ssh bravo zfs recv, from inside alpha" \
    -- cluster_exec alpha /tmp/replicate.sh

t_stdout_is "${bravo_ds}/from-alpha@s1" \
    "the snapshot arrived on bravo" \
    -- cluster_exec bravo zfs list -H -o name -t snapshot \
        "${bravo_ds}/from-alpha@s1"

# ---------------------------------------------------------------------------
# Informational probe: CARP. Recorded, never asserted -- M3 decides what to do
# with the answer, and this stage must not start failing because a kernel
# module moved.
# ---------------------------------------------------------------------------

probes=${REAPER_OUT:-$( t_tmpdir )}/cluster-probes.txt
alpha_epb="$( cluster_epair alpha )b"

{
    echo "# seance shape-A informational probes"
    echo "# date: $( date -u +%Y-%m-%dT%H:%M:%SZ )"
    echo "# uname: $( uname -a )"
    echo
    echo "== kldload carp (guest host)"
    kldload -n carp 2>&1
    echo "# exit: $?"
    echo
    echo "== kldstat | carp"
    kldstat 2>&1
    echo
    echo "== sysctl net.inet.carp"
    sysctl net.inet.carp 2>&1
    echo "# exit: $?"
    echo
    echo "== ifconfig ${alpha_epb} vhid 1, inside the vnet jail sn-alpha"
    cluster_exec alpha ifconfig "${alpha_epb}" vhid 1 pass seance \
        alias 192.0.2.100/32 2>&1
    echo "# exit: $?"
    echo
    echo "== ifconfig ${alpha_epb} inside sn-alpha, after the attempt"
    cluster_exec alpha ifconfig "${alpha_epb}" 2>&1
    echo "# exit: $?"
    echo
    echo "== ifconfig -C (cloners available inside sn-alpha)"
    cluster_exec alpha ifconfig -C 2>&1
    echo "# exit: $?"
} > "${probes}" 2>&1

t_diag "CARP probe recorded to ${probes}"

# Whatever the probe did, alpha must be left as it was found.
cluster_exec alpha ifconfig "${alpha_epb}" -vhid >/dev/null 2>&1
cluster_exec alpha ifconfig "${alpha_epb}" -alias 192.0.2.100 >/dev/null 2>&1

# ---------------------------------------------------------------------------
# Isolation: the link goes, the jail stays
# ---------------------------------------------------------------------------

cluster_isolate alpha || t_diag "cluster_isolate alpha failed"

t_rc 2 "isolated: bravo cannot reach alpha" \
    -- cluster_exec bravo ping -c 1 -t 2 "$( cluster_ip alpha )"
t_rc 2 "isolated: alpha cannot reach bravo" \
    -- cluster_exec alpha ping -c 1 -t 2 "$( cluster_ip bravo )"
t_rc 0 "isolated: alpha's jail is still alive" \
    -- cluster_exec alpha true

cluster_heal alpha || t_diag "cluster_heal alpha failed"

t_rc 0 "healed: bravo reaches alpha again" \
    -- cluster_exec bravo ping -c 1 -t 5 "$( cluster_ip alpha )"

# ---------------------------------------------------------------------------
# Stop and start a node: the jail goes, the state stays
# ---------------------------------------------------------------------------

cluster_exec charlie sh -c 'echo persisted > /seance/marker' ||
    t_diag "could not write charlie's marker"

cluster_stop charlie || t_diag "cluster_stop charlie failed"
t_is "$( jail_names )" "sn-alpha sn-bravo " "cluster_stop removed sn-charlie"

cluster_start charlie || t_diag "cluster_start charlie failed"
t_is "$( jail_names )" "sn-alpha sn-bravo sn-charlie " \
    "cluster_start brought sn-charlie back"
t_rc 0 "ssh alpha -> charlie works again after a restart" \
    -- node_ssh alpha charlie true
t_stdout_is "persisted" "charlie's on-disk state survived the restart" \
    -- cluster_exec charlie cat /seance/marker

# ---------------------------------------------------------------------------
# Teardown, and the cleanliness contract
# ---------------------------------------------------------------------------

cluster_dir_path=$( cluster_dir )
cluster_base_ds=$( cluster_base_dataset )
ifaces_before=$( cluster_ifaces )

t_rc 0 "cluster_down succeeds" -- cluster_down

t_is "$( jail_names )" "" "no sn-* jails remain"

work=$( t_tmpdir )

zfs list -H -o name > "${work}/ds"
t_is "$( awk -v d="${cluster_base_ds}" \
    '$0 == d || index($0, d "/") == 1' "${work}/ds" )" "" \
    "no seance datasets remain"

ifconfig -l > "${work}/ifl"
leftover=""
for i in ${ifaces_before}; do
    if grep -qw -- "${i}" "${work}/ifl"; then
        leftover="${leftover} ${i}"
    fi
done
t_is "${leftover}" "" "no bridge or epair of ours remains"

mount -p | awk -v d="${cluster_dir_path}/" 'index($2, d) == 1 { print $2 }' \
    > "${work}/mounts"
t_is "$( tr '\n' ' ' < "${work}/mounts" )" "" \
    "no mounts remain under the cluster directory"

t_is "$( authkeys_fingerprint )" "${ak_before}" \
    "the guest host's authorized_keys is byte-identical to before"

if [ -e "${cluster_dir_path}" ]; then
    t_not_ok "the cluster directory is gone"
    t_diag "still present: ${cluster_dir_path}"
else
    t_ok "the cluster directory is gone"
fi

# ---------------------------------------------------------------------------
# Idempotence: down twice, then up again
# ---------------------------------------------------------------------------

t_rc 0 "cluster_down is idempotent" -- cluster_down

t_rc 0 "cluster_up works again after a cluster_down" -- cluster_up 3
t_is "$( jail_names )" "sn-alpha sn-bravo sn-charlie " \
    "the second cluster is running"
t_rc 0 "the second cluster tears down cleanly" -- cluster_down

t_done
