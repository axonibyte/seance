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

t_plan 49

TAB=$( printf '\t.' )
TAB=${TAB%.}

estate_up || { t_diag "estate_up failed"; t_done; }

BASE_DS=$( cluster_base_dataset )

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
t_like "$( cat "${PROMOTE_OUT}" )" '^promote: 2 of 2 guest\(s\) promoted from alpha' \
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

# --- the records -------------------------------------------------------------

SUCCESSION=$( cluster_exec bravo cat /var/db/seance/succession.log < /dev/null )
t_like "${SUCCESSION}" "^web01${TAB}alpha${TAB}bravo${TAB}[0-9]{8}T[0-9]{6}Z${TAB}fence:jail\$" \
    "the succession record names the guest, both homes, the instant and the FENCE as evidence"
t_like "${SUCCESSION}" "^db01${TAB}alpha${TAB}bravo${TAB}[0-9]{8}T[0-9]{6}Z${TAB}fence:jail\$" \
    "one record per guest"

PLACEMENT=$( node_seance bravo placement )
t_like "${PLACEMENT}" "^placement${TAB}web01${TAB}alpha\$" \
    "placement says bravo is hosting web01 away from its home"
t_like "${PLACEMENT}" '^placement: 2 guest\(s\) hosted away from home$' \
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
t_like "$( cat "${REVERSE}" )" '^repl: 2 guests x 4 pairs, 2 ok, 2 failed, 0 skipped, 0 in progress$' \
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
