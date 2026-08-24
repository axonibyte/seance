#!/bin/sh
# Tier 6, stage 'promote' -- the succession ladder against a real pseudo-cluster.
#
# Three vnet jails, real ZFS lineage, real ssh, a fence driver whose "power off"
# is stopping the target's jail and whose "verified off" is the guest host's own
# `jls -d` no longer listing it. seance's own verbs are what runs: nothing here
# reimplements a rung or reaches around one.
#
# What is asserted is what a survivor would need to be true the morning after:
#
#   * the ladder's rungs are walked in order and each says what it decided;
#   * the fence was REAL -- the corpse's jail is gone from the host's jls, and
#     the succession record says fence:jail rather than force:<somebody>;
#   * the replicas are mounted IN PLACE, at the paths the platform expects,
#     with the data that was on the source;
#   * the guests are registered here and running here;
#   * succession.log and placement say so, and the RPO was reported;
#   * the next replication tick sends @seance-bravo-* onward, without anything
#     being configured to make it;
#   * and EXACTLY ONE survivor acted -- asserted from the second heir's state,
#     not from its exit code.
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

stage_begin promote

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/cluster.subr
. "${T_ROOT}/tests/cluster/lib/cluster.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/fence.subr
. "${T_ROOT}/tests/cluster/lib/fence.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/lib/estate.subr
. "${T_ROOT}/tests/cluster/lib/estate.subr"

export SEANCE_ROOT="${T_ROOT}"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "the promote stage builds jails and ZFS datasets; it needs root"
    echo "t_promote: must run as root" >&2
    exit 2
fi

t_plan 68

TAB=$( printf '\t.' )
TAB=${TAB%.}

estate_up || { t_diag "estate_up failed"; t_done; }

BASE_DS=$( cluster_base_dataset )

# ---------------------------------------------------------------------------
# A THIRD GUEST, IN THE SHAPE THE FIRST REAL FLEET IS BUILT IN (D-178, D-181)
#
# Every guest on that fleet is a bhyve VM whose data lives on the JAIL-shaped
# path -- nothing at all is where this platform's creation convention for a VM
# would put it. Until this stage carried one, every guest in the pseudo-cluster
# lived exactly where the convention said, so a ceremony that DERIVED the mount
# path and one that READ it were indistinguishable here, and the fleet was the
# first place the difference could show.
#
# vmj01's data path is named by its own configuration and by nothing else. If
# rung 6 derived the path, its replica would be mounted at /seance/vmj01, the
# registration would name /seance/vmdata/vmj01-data, and the guest would start
# over an empty directory -- which is precisely what would have happened on the
# fleet.
VMJ_DATA=/seance/vmdata/vmj01-data

estate_guest_create alpha vmj01 bhyve alpha 1 "${VMJ_DATA}" ||
    t_diag "creating vmj01 failed"
node_sh alpha "echo vmj01-v1 > ${VMJ_DATA}/marker" ||
    t_diag "writing vmj01's marker failed"

# ---------------------------------------------------------------------------
# Lineage first: a promotion has nothing to promote without one
# ---------------------------------------------------------------------------

t_rc 0 "the fleet configuration validates on alpha" \
    -- node_seance alpha config --check
# The mesh prerequisite, tested the way it is used: over ssh, where the PATH is
# the login class's and not any shell's. `seance placement` is what one node
# runs on another, and a node that cannot answer it is a node the gate and the
# ladder both read as silent.
# shellcheck disable=SC2119
#   Deliberately no identity argument: this connection is made from the guest
#   host, where the key is at cluster_key's path.
SSH_OPTS=$( cluster_ssh_opts )
# shellcheck disable=SC2086
#   Deliberate word splitting: ${SSH_OPTS} is an option list.
t_rc 0 "seance is on PATH for an ssh session on bravo (the mesh prerequisite)" \
    -- ssh ${SSH_OPTS} "root@$( cluster_ip bravo )" 'command -v seance'

t_rc 0 "a replication tick on alpha" -- estate_replicate

# A jail's ${jailsysdir}/<n>/ is what `repl` mirrors into the configuration
# dataset on real CBSD (D-82). The pseudo-cluster's guests keep their
# configuration inside their own datasets and so never need it -- so the mirror
# is seeded by hand here, standing in for that directory, and what is asserted
# below is the part shape A can prove: that it crosses, intact, hidden, and
# readable by the ceremony that would use it.
#
# AFTER the first tick, not before: the tick is what creates the mirror dataset
# and mounts it at <state-dir>/sys, and anything seeded into that directory
# beforehand is shadowed by the mount and never replicates. (Found by this
# stage's first real run, where the probe below came back empty.)
node_sh alpha 'mkdir -p /var/db/seance/sys/web01 &&
    echo mirrored-rcconf > /var/db/seance/sys/web01/rc.conf_web01' ||
    t_diag "seeding alpha's configuration mirror failed"

t_rc 0 "a second tick, carrying the seeded configuration mirror" \
    -- estate_replicate

# oracle_capture <dir> <live-node>...
#
# One observed state, in the format of invariants.subr's header. Every
# mandatory file is created even when it is empty: a missing file is a contract
# error there, deliberately, and this must not be the thing that hides one.
oracle_capture()
{
    local _d _n _g _st _ds

    _d=$1
    shift

    mkdir -p "${_d}" || return 1
    : > "${_d}/running"
    : > "${_d}/placement"
    : > "${_d}/snapshots"
    : > "${_d}/records"
    : > "${_d}/props"
    : > "${_d}/datasets"
    : > "${_d}/invocations"

    for _n in "$@"; do
        _st=$( node_seance "${_n}" status --tsv 2>/dev/null ) || _st=""

        printf '%s\n' "${_st}" |
            awk -F "${TAB}" -v n="${_n}" \
                '$1 == "guest" { print $2 "\t" n "\t" ($5 == "yes" ? 1 : 0) }' \
            >> "${_d}/running"

        printf '%s\n' "${_st}" |
            awk -F "${TAB}" -v n="${_n}" \
                '$1 == "guest" && $6 == "yes" { print n "\t" $2 "\theld" }' \
            >> "${_d}/placement"

        node_seance "${_n}" placement 2>/dev/null |
            awk -F "${TAB}" -v n="${_n}" \
                '$1 == "placement" { print n "\t" $2 "\tactive" }' \
            >> "${_d}/placement"

        cluster_exec "${_n}" cat /var/db/seance/succession.log < /dev/null 2>/dev/null |
            awk -v n="${_n}" 'NF > 0 { print n "\t" $0 }' >> "${_d}/records"
    done

    # From the host: every dataset of the estate, and which node holds it.
    zfs list -H -o name -r "${BASE_DS}" 2>/dev/null |
        awk -F '/' -v b="${BASE_DS}" -v n=0 '
            { n = split(b, p, "/"); if (NF > n) print $(n + 1) "\t" $0 }' \
        >> "${_d}/datasets"

    # And per (node, guest): the snapshots of that node's copy, and -- for the
    # REPLICAS only -- the two properties invariant 4a reads.
    #
    # ONLY THE REPLICAS, and the reason is a gap in the invariant rather than a
    # convenience here. Invariant 4a exempts the node the guest is placed on
    # and calls every other copy a replica that must be unmountable. After a
    # promotion the guest's HOME still holds the original, mounted where the
    # platform put it -- alpha's own <base>/alpha/web01 reads
    # mountpoint=/seance/web01 -- so a capture that offered it would fire 4a on
    # every correct post-promotion state. The original is not a shadow mount;
    # what stops the home starting it again is the boot gate (D-21), which is
    # invariant 1's business and not 4a's. Written down in decisions.md for M3,
    # whose world driver has to answer the same question.
    for _n in alpha bravo charlie; do
        for _g in web01 db01 vmj01; do
            if [ "${_n}" = alpha ]; then
                _ds="${BASE_DS}/alpha/${_g}"
            else
                _ds=$( estate_replica_root "${_n}" alpha "${_g}" )
            fi

            zfs list -H -o name "${_ds}" > /dev/null 2>&1 || continue

            zfs list -H -o name -t snapshot -r "${_ds}" 2>/dev/null |
                awk -F '@' -v n="${_n}" -v g="${_g}" -v d="${_ds}" \
                    'NF == 2 && $1 == d { print n "\t" g "\t" $2 }' \
                >> "${_d}/snapshots"

            [ "${_n}" = alpha ] && continue

            printf '%s\t%s\tcanmount\t%s\n' "${_n}" "${_g}" \
                "$( zfs get -H -o value canmount "${_ds}" 2>/dev/null )" \
                >> "${_d}/props"
            printf '%s\t%s\tmountpoint\t%s\n' "${_n}" "${_g}" \
                "$( zfs get -H -o value mountpoint "${_ds}" 2>/dev/null )" \
                >> "${_d}/props"
        done
    done

    return 0
}

ORACLE_DIR=$( t_tmpdir )/oracle
mkdir -p "${ORACLE_DIR}"

# The tier-7 checker's "before" observation, taken while every node is alive --
# it has to happen here, because after the next section alpha is a corpse and
# its own placement and log can no longer be asked for.
oracle_capture "${ORACLE_DIR}/pre" alpha bravo charlie ||
    t_diag "capturing the state before the death failed"

WEB_ON_BRAVO=$( estate_replica_root bravo alpha web01 )
WEB_ON_CHARLIE=$( estate_replica_root charlie alpha web01 )
DB_ON_BRAVO=$( estate_replica_root bravo alpha db01 )

t_rc 0 "web01 has a replica on bravo" -- nz bravo list -H -o name "${WEB_ON_BRAVO}"
t_rc 0 "web01 has a replica on charlie" -- nz charlie list -H -o name "${WEB_ON_CHARLIE}"
t_rc 0 "db01 has a replica on bravo" -- nz bravo list -H -o name "${DB_ON_BRAVO}"

# ---------------------------------------------------------------------------
# The fence driver, exercised on its own before the ladder depends on it
# ---------------------------------------------------------------------------

t_rc 1 "fence_jail reports a running node as ON" \
    -- cluster_exec bravo /usr/local/bin/fence_jail status alpha
t_rc 2 "fence_jail refuses an action it does not have" \
    -- cluster_exec bravo /usr/local/bin/fence_jail poweroff alpha

# ---------------------------------------------------------------------------
# alpha dies
# ---------------------------------------------------------------------------

cluster_stop alpha || t_diag "cluster_stop alpha failed"

t_rc 1 "alpha's jail is gone from the guest host's jls" \
    -- jls -d -j "$( cluster_jail_name alpha )" jid

t_rc 0 "and fence_jail, asked from bravo, now reports it OFF" \
    -- cluster_exec bravo /usr/local/bin/fence_jail status alpha

# ---------------------------------------------------------------------------
# The ladder, on bravo -- and on charlie at the same time
#
# charlie is alpha's SECOND heir. It must stand down because bravo, the first
# heir, is reachable -- and that must be true from charlie's own state
# afterwards, not from the order the two commands happened to finish in.
# ---------------------------------------------------------------------------

CHARLIE_OUT=$( t_tmpdir )/charlie.out
node_seance charlie promote alpha > "${CHARLIE_OUT}" 2>&1 &
CHARLIE_PID=$!

PROMOTE_OUT=$( t_tmpdir )/promote.out
node_seance bravo promote alpha > "${PROMOTE_OUT}" 2>&1
PROMOTE_RC=$?

wait "${CHARLIE_PID}"
CHARLIE_RC=$?

t_is "${PROMOTE_RC}" "0" "the promotion on bravo exits 0"

# --- the rungs, in order, each with a verdict -------------------------------
t_like "$( cat "${PROMOTE_OUT}" )" '^rung 1 debounce: n/a \(manual\)' \
    "rung 1 debounce reports n/a for a promotion a human typed"
t_like "$( cat "${PROMOTE_OUT}" )" '^rung 2 quorum: pass' \
    "rung 2 quorum formed a majority"
t_like "$( cat "${PROMOTE_OUT}" )" '^rung 3 probes: pass' \
    "rung 3 probes found alpha answering neither ping nor ssh"
t_like "$( cat "${PROMOTE_OUT}" )" '^rung 4 fence: pass' \
    "rung 4 fence verified alpha off through the driver"
t_like "$( cat "${PROMOTE_OUT}" )" 'fence_jail off alpha verified' \
    "and the driver said so in its own words"
t_like "$( cat "${PROMOTE_OUT}" )" '^rung 5 lineage: pass' \
    "rung 5 found alpha's estate under the standby tree"
t_like "$( cat "${PROMOTE_OUT}" )" '^rung 6 promotion: pass' \
    "rung 6 promoted it"
t_like "$( cat "${PROMOTE_OUT}" )" '^rung 7 post: ' \
    "rung 7 says what the next replication tick will do"
t_like "$( cat "${PROMOTE_OUT}" )" 'RPO ' \
    "the promotion reports what it cost"
t_like "$( cat "${PROMOTE_OUT}" )" '^  undo: ' \
    "every mutating step printed its undo"
t_like "$( cat "${PROMOTE_OUT}" )" '^promote: 3 of 3 guest\(s\) promoted from alpha' \
    "and the verdict line counts the estate"

# --- the disks, which are the only account that matters ---------------------

t_is "$( nz bravo get -H -o value mountpoint "${WEB_ON_BRAVO}" )" "/seance/web01" \
    "web01's replica is mounted IN PLACE at the path the platform expects"
t_is "$( nz bravo get -H -o value canmount "${WEB_ON_BRAVO}" )" "noauto" \
    "and canmount is still noauto: the mount was explicit, not automatic"
t_is "$( nz bravo get -H -o value mounted "${WEB_ON_BRAVO}" )" "yes" \
    "and it is actually mounted"
t_is "$( nz bravo get -H -o value mountpoint "${WEB_ON_BRAVO}/data" )" \
    "/seance/web01/data" \
    "the child dataset came with it, at the path below the root"

t_stdout_is "web01-v1" "the data on the survivor is the data that was on the source" \
    -- cluster_exec bravo cat /seance/web01/marker
t_stdout_is "web01-child-v1" "and the child dataset's data came too" \
    -- cluster_exec bravo cat /seance/web01/data/marker

t_is "$( nz bravo get -H -o value mountpoint "${BASE_DS}/bravo/standby" )" "none" \
    "the standby PARENT was left alone: it still cannot mount"

# --- and the guest whose data is NOT where the convention would put it -------
#
# The assertion the fleet needed and could not get: a replica mounted where the
# guest's own configuration says, on a path no derivation from this node's
# layout could have produced.
VMJ_ON_BRAVO=$( estate_replica_root bravo alpha vmj01 )

t_is "$( nz bravo get -H -o value mountpoint "${VMJ_ON_BRAVO}" )" "${VMJ_DATA}" \
    "vmj01's replica is mounted where its OWN configuration says its data lives"
t_isnt "$( nz bravo get -H -o value mountpoint "${VMJ_ON_BRAVO}" )" "/seance/vmj01" \
    "and NOT at the path this platform's convention for the type would have derived"
t_is "$( nz bravo get -H -o value canmount "${VMJ_ON_BRAVO}" )" "noauto" \
    "with canmount still noauto, like every other replica"
t_is "$( nz bravo get -H -o value mounted "${VMJ_ON_BRAVO}" )" "yes" \
    "and it really is mounted"
t_stdout_is "vmj01-v1" "and the data that was on the source is on the survivor" \
    -- cluster_exec bravo cat "${VMJ_DATA}/marker"
t_like "$( cat "${PROMOTE_OUT}" )" \
    "vmj01: its own configuration in .* says data=${VMJ_DATA}" \
    "the ladder says where it read the path, and out of which replica"
t_like "$( cat "${PROMOTE_OUT}" )" \
    "vmj01: the platform looks for its data at ${VMJ_DATA}, which is where its replica is mounted" \
    "and it checked its own work against the platform after registering the guest"

# The platform's own record on the survivor, read from the file the pseudo
# adapter keeps it in: bravo now says vmj01's data is where alpha said it was.
t_stdout_is "${VMJ_DATA}" \
    "and bravo's registration of vmj01 carries the data path it was registered with" \
    -- cluster_exec bravo sh -c \
    "awk -F'\t' '\$1 == \"vmj01\" { print \$7 }' /var/db/seance-pseudo/guests.tsv"

# --- the platform's own account ---------------------------------------------

# The home column is deliberately not pinned. `status` prints the REPORTING
# node's own key there for every guest, which was exactly right until this
# milestone made it possible for a node to host a guest whose home is somewhere
# else -- and `placement` is now the record that would say so. Whether status
# should read it is a question for the orchestrator, not something to settle by
# writing an assertion that locks in either answer; it is in the report.
STATUS_TSV=$( node_seance bravo status --tsv )
t_like "${STATUS_TSV}" "^guest${TAB}web01${TAB}jail${TAB}[a-z]+${TAB}yes${TAB}no\$" \
    "bravo reports web01 as a running, unheld guest"
t_like "${STATUS_TSV}" "^guest${TAB}db01${TAB}bhyve${TAB}[a-z]+${TAB}yes${TAB}no\$" \
    "and db01 too"
t_like "${STATUS_TSV}" "^guest${TAB}vmj01${TAB}bhyve${TAB}[a-z]+${TAB}yes${TAB}no\$" \
    "and vmj01, the one whose data is not where a derivation would look, is running here too"

# --- the records -------------------------------------------------------------

SUCCESSION=$( cluster_exec bravo cat /var/db/seance/succession.log < /dev/null )
t_like "${SUCCESSION}" "^web01${TAB}alpha${TAB}bravo${TAB}[0-9]{8}T[0-9]{6}Z${TAB}fence:jail\$" \
    "the succession record names the guest, both homes, the instant and the FENCE as evidence"
t_like "${SUCCESSION}" "^db01${TAB}alpha${TAB}bravo${TAB}[0-9]{8}T[0-9]{6}Z${TAB}fence:jail\$" \
    "one record per guest"

PLACEMENT=$( node_seance bravo placement )
t_like "${PLACEMENT}" "^placement${TAB}web01${TAB}alpha\$" \
    "placement says bravo is hosting web01 away from its home"
t_like "${PLACEMENT}" '^placement: 3 guest\(s\) hosted away from home$' \
    "and the verdict line counts them"

# ---------------------------------------------------------------------------
# EXACTLY ONE actor, read from charlie's state rather than from its exit code
# ---------------------------------------------------------------------------

t_is "$( node_seance charlie placement | awk -F "${TAB}" '$1 == "placement" { print $2 }' )" \
    "" "charlie claims nothing: the second heir stood down"
t_rc 1 "and charlie never registered web01" \
    -- cluster_exec charlie sh -c \
    "awk -F'\t' '\$1 == \"web01\"' /var/db/seance-pseudo/guests.tsv | grep ."
t_like "$( cat "${CHARLIE_OUT}" )" 'stand-down' \
    "charlie said so, having been asked at the same time (exit ${CHARLIE_RC})"

# ---------------------------------------------------------------------------
# The dead node's configuration mirror, on the successor (D-82)
#
# This is what rung 6 reads a jail's rc.conf out of when the guest's own
# datasets did not carry it. Shape A's guests do carry it, so what is asserted
# is the MECHANISM: the mirror crossed, it is hidden like every other replica,
# and mounting it read-only -- exactly what promote_sys_restore does -- yields
# the configuration the dead node had. That a real jail then registers from it
# is tier 5's (tests/tier5/README).
# ---------------------------------------------------------------------------

SYS_ON_BRAVO=$( estate_replica_root bravo alpha seance-sys )

t_rc 0 "alpha's configuration mirror crossed to bravo" \
    -- nz bravo list -H -o name "${SYS_ON_BRAVO}"
t_is "$( nz bravo get -H -o value mountpoint "${SYS_ON_BRAVO}" )" "none" \
    "and it is hidden on arrival, like every other replica"

# The mountpoint is put back whatever the read does -- a probe that leaves a
# replica mounted because the thing it was reading was missing would turn one
# failed assertion into two, and the second would be the fixture's fault.
t_stdout_is "mirrored-rcconf" \
    "mounting it READ-ONLY yields the configuration alpha had -- which is what rung 6 does" \
    -- node_sh bravo "mkdir -p /tmp/sysprobe &&
        zfs set mountpoint=/tmp/sysprobe ${SYS_ON_BRAVO} &&
        zfs mount -o ro ${SYS_ON_BRAVO} &&
        cat /tmp/sysprobe/web01/rc.conf_web01
        _rc=\$?
        zfs unmount ${SYS_ON_BRAVO} > /dev/null 2>&1
        zfs inherit mountpoint ${SYS_ON_BRAVO} > /dev/null 2>&1
        exit \$_rc"

t_is "$( nz bravo get -H -o value mountpoint "${SYS_ON_BRAVO}" )" "none" \
    "and putting it back leaves it mounted nowhere, as it was"


# ---------------------------------------------------------------------------
# The tier-7 checker's state-file contract, met by a real cluster
#
# tests/tier4/t_oracle_m2.sh feeds the invariants the records a real rung 6
# writes, with the pool and the peers stood in for. This does the same thing
# with none of it stood in for: the placement files, succession logs, snapshot
# names, ZFS properties and dataset lists below are read off three real nodes
# and the guest host's own pool, and handed to tests/cluster/sim/invariants.subr
# in the format its header specifies.
#
# TWO states, before and after the death, so that invariants 3 and 4 -- the
# transition ones -- have two real observations to compare rather than a model
# nobody wrote. THE DATASETS ARE READ FROM THE HOST, which is the contract's own
# instruction and the reason it gives: a node being dead is not a reason for its
# datasets to stop existing, and an observer that could not see a stopped node's
# datasets would turn invariant 4 into a check that fires on every kill.
# ---------------------------------------------------------------------------

oracle_capture "${ORACLE_DIR}/cur" bravo charlie ||
    t_diag "capturing the state after the promotion failed"

mkdir -p "${ORACLE_DIR}/model"
printf 'alpha\tdead\nbravo\talive\ncharlie\talive\n' > "${ORACLE_DIR}/model/nodes"
printf 'web01\talpha\ndb01\talpha\nvmj01\talpha\n' > "${ORACLE_DIR}/model/guests"
: > "${ORACLE_DIR}/model/lineage"

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../cluster/sim/invariants.subr
. "${T_ROOT}/tests/cluster/sim/invariants.subr"

oracle_check()
{
    INV_FIRED=0
    inv_check_all "${ORACLE_DIR}/model" "$1" "${2:-}" \
        > "${ORACLE_DIR}/inv.out" 2> "${ORACLE_DIR}/inv.err"
    printf '%s\n' "$?"
}

MISSING=""
for f in running placement snapshots records props datasets invocations; do
    [ -f "${ORACLE_DIR}/cur/${f}" ] || MISSING="${MISSING} ${f}"
done
t_is "${MISSING}" "" "the capture wrote every file the state contract makes mandatory"

t_rc 0 "and the placement it captured is bravo's own, with a claim in it" \
    -- grep -q "^bravo	web01	active$" "${ORACLE_DIR}/cur/placement"
t_rc 0 "and the records it captured are bravo's succession log" \
    -- grep -q "^bravo	web01	alpha	bravo	" "${ORACLE_DIR}/cur/records"
t_rc 0 "and it saw the DEAD node's datasets, from the host" \
    -- grep -q "^alpha	${BASE_DS}/alpha/web01$" "${ORACLE_DIR}/cur/datasets"

RC=$( oracle_check "${ORACLE_DIR}/cur" "${ORACLE_DIR}/pre" )
if [ "${RC}" = "0" ]; then
    t_ok "no invariant fires on a real cluster's real promotion"
else
    t_not_ok "no invariant fires on a real cluster's real promotion"
    grep -E 'FIRED' "${ORACLE_DIR}/inv.out" | sed -e 's/^/# /'
    sed -e 's/^/# stderr: /' "${ORACLE_DIR}/inv.err"
fi
t_is "$( cat "${ORACLE_DIR}/inv.err" )" "" \
    "and the checker had nothing to say about the shape of what it was given"

# And the negative controls, on copies of the REAL state -- which is the half a
# hand-built fixture cannot do: an invariant that a real record was passing by
# accident shows up here and nowhere else.
oracle_break()
{
    rm -rf "${ORACLE_DIR}/bad"
    cp -R "${ORACLE_DIR}/cur" "${ORACLE_DIR}/bad"
}

oracle_fires()
{
    local _rc

    _rc=$( oracle_check "${ORACLE_DIR}/bad" "${ORACLE_DIR}/pre" )
    if [ "${_rc}" = "1" ] && grep -q "^invariant $1 FIRED" "${ORACLE_DIR}/inv.out"; then
        t_ok "$2"
    else
        t_not_ok "$2"
        sed -e 's/^/# /' "${ORACLE_DIR}/inv.out"
    fi
}

oracle_break
printf 'charlie\tweb01\tactive\n' >> "${ORACLE_DIR}/bad/placement"
oracle_fires 1 "a second node claiming web01 active fires invariant 1 on the real state"

oracle_break
: > "${ORACLE_DIR}/bad/records"
oracle_fires 2 "the same state with the succession log emptied fires invariant 2"

oracle_break
grep -v "^alpha	" "${ORACLE_DIR}/cur/datasets" > "${ORACLE_DIR}/bad/datasets"
oracle_fires 4 "and the dead node's datasets going missing fires invariant 4"

oracle_break
sed -e "s/^charlie	web01	canmount	noauto$/charlie	web01	canmount	on/" \
    "${ORACLE_DIR}/cur/props" > "${ORACLE_DIR}/bad/props"
oracle_fires 4a "a replica left able to mount itself fires invariant 4a"

# ---------------------------------------------------------------------------
# The direction reverses, with nothing configured to make it
# ---------------------------------------------------------------------------

# It cannot exit 0, and that is rung 7's own words: the pair pointing at the
# dead node fails and is logged as failed, not fatal, while every other pair
# goes through. Asserting 0 here would have been asserting that a dead node
# answers.
REVERSE=$( t_tmpdir )/reverse.out
node_seance bravo repl --now > "${REVERSE}" 2>&1
REVERSE_RC=$?

t_is "${REVERSE_RC}" "1" \
    "a tick on the successor reports failure, because one of its peers is the corpse"
t_like "$( cat "${REVERSE}" )" '^repl: 3 guests x 6 pairs, 3 ok, 3 failed, 0 skipped, 0 in progress$' \
    "and the verdict line counts them: every pair to a living peer went through"
t_like "$( cat "${REVERSE}" )" '^repl: configuration mirror: 2 pairs, 1 ok, 1 failed, 0 in progress$' \
    "the mirror is counted on a line of its own, because it is not a guest"
t_like "$( cat "${REVERSE}" )" '^info: repl seance-sys->charlie: 1 stream' \
    "and it reversed direction with the guests, without being configured to" 

WEB_ON_CHARLIE_FROM_BRAVO=$( estate_replica_root charlie bravo web01 )
t_rc 0 "bravo now replicates web01 to charlie under ITS OWN home key" \
    -- nz charlie list -H -o name "${WEB_ON_CHARLIE_FROM_BRAVO}"
t_like "$( nz charlie list -H -o name -t snapshot "${WEB_ON_CHARLIE_FROM_BRAVO}" )" \
    '@seance-bravo-[0-9]{8}T[0-9]{6}Z$' \
    "and the snapshots carry bravo's lineage, because the home in the name is the node taking it"

t_done
