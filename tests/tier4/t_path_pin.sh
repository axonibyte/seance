#!/bin/sh
# Tier 4 -- nothing may precede the base system in seance's PATH (D-171).
#
# THE DEFECT, on a real three-node cluster and found with truss(1). The module's
# CBSD verb wrapper runs under cbsdsh, and CBSD puts ${workdir}/modules FIRST in
# PATH -- that directory is its dispatch mechanism, and it holds a verb for
# every enabled module. One of them is called `ssh`. Every bare `ssh` the
# dispatcher issued from wrapper context therefore ran CBSD's ssh VERB:
# `seance verify` FAILED every mesh probe on the fleet while the identical
# command typed by hand succeeded, and no tier noticed, because every tier drove
# bin/seance with the harness's own PATH. That is D-170's rule -- a tier tests
# the CALLER's environment -- one level below where D-170 was written.
#
# SO THIS FILE BUILDS THE CALLER. `env -i`, and then exactly what cbsdsh hands a
# verb: a PATH whose first entry is a modules directory, and the SEANCE_CBSD_*
# facts the wrapper exports. The modules directory here holds a verb for every
# external command seance depends on -- ssh, zfs, logger, timeout, lockf,
# daemon, realpath, ping -- and each of them records that it ran and then lies.
# None of them may ever execute.
#
# THE FAKES ARE NOT ALL EQUAL, and that is the point of shadowing the whole set
# rather than ssh alone:
#   realpath  bin/seance's own first external command: if it is shadowed, the
#             dispatcher cannot even find its libraries;
#   lockf     the one that would be silent -- a `lockf` that locks nothing
#             still exits 0, and one ladder per corpse (D-155) would quietly
#             become as many as devd cared to start;
#   timeout   every bound seance places on a peer;
#   ssh       the mesh itself, which is the one that bit.
#
# AND THE SITE'S OWN COMMANDS ARE STILL FOUND. `notify_cmd` and a fence driver
# the module does not ship are documented to be found on PATH; the pin puts the
# base directories in FRONT rather than throwing the caller's PATH away, so a
# site's directory still answers for names the base system does not have. Both
# halves are asserted, because a fix that took the second one away would have
# broken every site that pages.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SEANCE="${T_ROOT}/bin/seance"
WORK=$( t_tmpdir )

t_plan 16

WORKDIR="${WORK}/workdir"
mkdir -p "${WORKDIR}/jails-system" "${WORKDIR}/jails-data"

# The platform's dispatch directory, exactly as cbsdsh presents it: first in
# PATH, and full of verbs named after the commands seance runs.
MODULES="${WORK}/modules"
mkdir -p "${MODULES}"
SHADOWED="ssh zfs zpool logger timeout lockf daemon realpath ping"
for v in ${SHADOWED}; do
    cat > "${MODULES}/${v}" <<EOF
#!/bin/sh
# The platform's own verb of this name. It records that it ran, and lies.
printf '%s %s\n' "${v}" "\$*" >> "\${SEANCE_TEST_SHADOWLOG}"
exit 0
EOF
    chmod 0755 "${MODULES}/${v}"
done

SHADOWLOG="${WORK}/shadow.log"
: > "${SHADOWLOG}"

# The site's own pager, in that same directory, named bare in the
# configuration -- so it can only be found through the tail of PATH.
cat > "${MODULES}/sitepager" <<'EOF'
#!/bin/sh
# Records the PATH seance handed it, which is the only place from outside the
# process where the pinned value can be read.
printf '%s\n' "${PATH}" > "${SEANCE_TEST_PAGERPATH}"
printf 'subject: %s\n' "$*" >> "${SEANCE_TEST_PAGERLOG}"
cat > /dev/null
exit 0
EOF
chmod 0755 "${MODULES}/sitepager"
PAGERPATH="${WORK}/pager.path"
PAGERLOG="${WORK}/pager.log"
: > "${PAGERLOG}"

# alpha is the corpse, bravo is this node. Two nodes, so rung 2 freezes without
# probing anybody -- the ladder reaches the site's pager in milliseconds and
# without a network. The peers point at a port nothing listens on, so the mesh
# probe that DOES run gets a real refusal from the real ssh at once.
CONF="${WORK}/seance.conf"
cat > "${CONF}" <<EOF
cadence=900
debounce=0
standby_root=pool0/%n/standby
ssh_port=1
notify_cmd=sitepager

node_alpha_nodename=alpha
node_alpha_mgmt=127.0.0.1
node_alpha_heir=bravo

node_bravo_nodename=bravo
node_bravo_mgmt=127.0.0.2
node_bravo_heir=alpha
EOF

# cbsdsh <args...>  -- the verb as the CBSD wrapper's own environment runs it.
cbsdsh()
{
    env -i \
        PATH="${MODULES}:/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin" \
        HOME=/root LOGNAME=root USER=root SHELL=/bin/sh \
        SEANCE_CBSD_WORKDIR="${WORKDIR}" \
        SEANCE_CBSD_NODENAME=bravo \
        SEANCE_CONF="${CONF}" \
        SEANCE_ADAPTER="${T_ROOT}/tests/mock-adapter.subr" \
        SEANCE_ROOT="${T_ROOT}" \
        SEANCE_MOCK_NODE=bravo \
        SEANCE_MOCK_WORKDIR="${WORKDIR}" \
        SEANCE_TEST_SHADOWLOG="${SHADOWLOG}" \
        SEANCE_TEST_PAGERPATH="${PAGERPATH}" \
        SEANCE_TEST_PAGERLOG="${PAGERLOG}" \
        "${SEANCE}" "$@"
}

# shadowed_ran <name>  -- how many times the platform's verb of that name ran.
shadowed_ran()
{
    awk -v n="$1" '$1 == n { c++ } END { print c + 0 }' "${SHADOWLOG}"
}

# ---------------------------------------------------------------------------
# The dispatcher survives a shadowed `realpath`, which is how it finds itself
# ---------------------------------------------------------------------------

t_is "$( cbsdsh version )" "seance $( cat "${T_ROOT}/VERSION" )" \
    "the dispatcher runs at all under a PATH whose first entry shadows realpath(1)"
t_is "$( shadowed_ran realpath )" "0" \
    "-- because it never ran the platform's realpath verb"

# ---------------------------------------------------------------------------
# The mesh: the one that bit
# ---------------------------------------------------------------------------

: > "${SHADOWLOG}"
OUT="${WORK}/placement.out"
cbsdsh placement --remote > "${OUT}" 2>&1

t_is "$( shadowed_ran ssh )" "0" \
    "a verb that talks to peers does NOT run the platform's ssh verb"
t_is "$( shadowed_ran timeout )" "0" \
    "nor the platform's timeout, which is every bound seance places on a peer"
t_like "$( cat "${OUT}" )" 'from 0 living peer\(s\)' \
    "and the REAL ssh answered: a peer on a closed port is not a living peer"

# The fake would have exited 0 and printed nothing, which reads as a peer that
# answered with no claims -- the exact false pass D-96 is about.
t_unlike "$( cat "${OUT}" )" 'from 1 living peer' \
    "-- had the platform's ssh answered, silence would have counted as a peer with no claims"

# ---------------------------------------------------------------------------
# ZFS, and the lock
# ---------------------------------------------------------------------------

: > "${SHADOWLOG}"
cbsdsh repl --now > "${WORK}/repl.out" 2>&1

t_is "$( shadowed_ran zfs )" "0" \
    "a replication tick does not run the platform's zfs verb"

: > "${SHADOWLOG}"
: > "${PAGERLOG}"
cbsdsh promote alpha > "${WORK}/promote.out" 2>&1

t_is "$( shadowed_ran lockf )" "0" \
    "a promotion takes its corpse lock with the real lockf(1), not a verb of that name that locks nothing"
t_like "$( cat "${WORK}/promote.out" )" '^rung 2 quorum: notify' \
    "and the ladder ran, freezing at quorum as a two-node fleet must"

# ---------------------------------------------------------------------------
# The site's own commands are still found, and the pinned value is readable
# ---------------------------------------------------------------------------

t_like "$( cat "${PAGERLOG}" )" 'subject: seance: quorum frozen' \
    "notify_cmd, named bare, is still found through the tail of PATH -- the site's own extension point survives the pin"

PINNED=$( cat "${PAGERPATH}" )
t_like "${PINNED}" '^/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin' \
    "and the PATH seance exported begins with the base system, in hier(7)'s own order"
case ":${PINNED}:" in
    *":${MODULES}:"*)
        t_ok "the caller's own directory is still on it, after them"
        ;;
    *)
        t_not_ok "the caller's own directory is still on it, after them"
        t_diag "PATH was [${PINNED}]"
        ;;
esac

# IDEMPOTENT, because the dispatcher re-enters itself: `repl` once per pair and
# `promote` once under lockf(1). A pin that prepended six directories per level
# would grow the environment for as long as the recursion lasted.
t_is "$( printf '%s\n' "${PINNED}" | tr ':' '\n' | sort | uniq -d | tr '\n' ' ' )" "" \
    "and carries no directory twice"

REPIN=$( env -i \
    PATH="${PINNED}" \
    HOME=/root LOGNAME=root USER=root SHELL=/bin/sh \
    SEANCE_CBSD_WORKDIR="${WORKDIR}" SEANCE_CBSD_NODENAME=bravo \
    SEANCE_CONF="${CONF}" SEANCE_ADAPTER="${T_ROOT}/tests/mock-adapter.subr" \
    SEANCE_ROOT="${T_ROOT}" SEANCE_MOCK_NODE=bravo SEANCE_MOCK_WORKDIR="${WORKDIR}" \
    SEANCE_TEST_SHADOWLOG="${SHADOWLOG}" SEANCE_TEST_PAGERPATH="${WORK}/pager2.path" \
    SEANCE_TEST_PAGERLOG="${PAGERLOG}" \
    "${SEANCE}" promote alpha > /dev/null 2>&1; cat "${WORK}/pager2.path" )

t_is "${REPIN}" "${PINNED}" \
    "pinning an already-pinned PATH changes nothing: re-entry is idempotent"

# ---------------------------------------------------------------------------
# The whole surface, counted rather than promised
# ---------------------------------------------------------------------------

t_is "$( awk 'END { print NR + 0 }' "${SHADOWLOG}" )" "0" \
    "across every verb above, not one of the platform's shadowing verbs was executed"
t_is "$( shadowed_ran logger )" "0" \
    "the diagnostics went to the real logger(1) too"

t_done
