#!/bin/sh
# Tier 4 -- `verify --render` is byte-stable, and `verify` sees drift.
#
# `verify --render` is a file an operator redirects into place and then leaves
# alone for a year (docs/INSTALL.md). Two properties follow, and neither of
# them is checked anywhere else:
#
#   1. THE RENDERING IS A FUNCTION OF THE CONFIGURATION AND NOTHING ELSE. Run
#      twice it must be byte-identical, and run under another TZ or LC_ALL it
#      must be byte-identical too -- a rendering that moved with the locale
#      would make `verify` FAIL on a node whose cron runs under a different
#      environment from the operator's shell, which is the M1 loop's angle (i)
#      applied to the files M3 tells an operator to install.
#
#   2. WHAT VERIFY IS FOR IS DRIFT. Every check below is fed a world that is
#      right except in one named place -- an advskew somebody edited, a vhid
#      with no alias, preempt turned off, a devd rule pointing at some other
#      seance -- and has to name it. A verifier only ever run against a correct
#      node is a verifier nobody has tested.
#
# The world is shims (D-76): sysrc, sysctl and service on PATH, the file
# constants of lib/carp.subr and lib/verify.subr pointed at fixtures in this
# process (D-75's idiom -- a test that assigns a library constant takes the
# same path production does), and the mock adapter for this node's identity and
# its CARP states. The checks themselves are the real ones.
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
# shellcheck source=../../lib/verify.subr
. "${T_ROOT}/lib/verify.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../mock-adapter.subr
. "${T_ROOT}/tests/mock-adapter.subr"

WORK=$( t_tmpdir )
SHIM="${WORK}/bin"
mkdir -p "${SHIM}"

SEANCE_TMP_REGISTRY="${WORK}/registry"
: > "${SEANCE_TMP_REGISTRY}"
export SEANCE_TMP_REGISTRY
t_at_exit 'seance_tmp_cleanup'

SEANCE_STATE_DIR="${WORK}/state"
SEANCE_RUN_DIR="${WORK}/run"
export SEANCE_STATE_DIR SEANCE_RUN_DIR
mkdir -p "${SEANCE_STATE_DIR}" "${SEANCE_RUN_DIR}"

# --- the world -------------------------------------------------------------

cat > "${SHIM}/sysrc" <<'EOF'
#!/bin/sh
# sysrc -v -e -a, in the shape verify_rcvars asks for: "<file>: <name>=<value>"
set -u
cat "${WORLD_DIR}/rcvars"
exit 0
EOF

cat > "${SHIM}/sysctl" <<'EOF'
#!/bin/sh
set -u
[ "${1:-}" = "-n" ] || exit 1
_v=$( awk -v o="${2:-}" '$1 == o { print $2 }' "${WORLD_DIR}/sysctls" )
[ -n "${_v}" ] || exit 1
printf '%s\n' "${_v}"
exit 0
EOF

cat > "${SHIM}/service" <<'EOF'
#!/bin/sh
set -u
exit "$( cat "${WORLD_DIR}/service.rc" )"
EOF

cat > "${SHIM}/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "${SHIM}/pretend-platform" <<'EOF'
#!/bin/sh
exit 0
EOF

chmod 0755 "${SHIM}/sysrc" "${SHIM}/sysctl" "${SHIM}/service" \
    "${SHIM}/logger" "${SHIM}/pretend-platform"
PATH="${SHIM}:${PATH}"
export PATH

WORLD_DIR=${WORK}
export WORLD_DIR

printf '0\n' > "${WORK}/service.rc"

# The file constants, pointed at this test's own fixtures.
CARP_DEVD_PREFERRED="${WORK}/devd.conf"
CARP_DEVD_ALSO="${WORK}/devd-also.conf"
CARP_SYSCTL_CONF="${WORK}/sysctl.conf"
CARP_LOADER_CONF="${WORK}/loader.conf"
VERIFY_CRON_PREFERRED="${WORK}/cron.d-seance"
VERIFY_CRON_ALSO="${WORK}/cron.d-seance-also"

SEANCE_MOCK_NODE=bravo
SEANCE_MOCK_WORKDIR="${WORK}/workdir"
SEANCE_MOCK_LOG="${WORK}/mock.log"
SEANCE_MOCK_SCRIPT="${WORK}/mock.script"
SEANCE_MOCK_VERB="${SHIM}/pretend-platform seance"
export SEANCE_MOCK_NODE SEANCE_MOCK_WORKDIR SEANCE_MOCK_LOG SEANCE_MOCK_SCRIPT
export SEANCE_MOCK_VERB
mkdir -p "${SEANCE_MOCK_WORKDIR}"

# bravo is MASTER for its own vhid 2 and BACKUP for the two it may inherit.
{
    printf 'adapter_carp_state 1\tok\tBACKUP\n'
    printf 'adapter_carp_state 2\tok\tMASTER\n'
    printf 'adapter_carp_state 3\tok\tBACKUP\n'
} > "${SEANCE_MOCK_SCRIPT}"

CONF="${WORK}/seance.conf"
cat > "${CONF}" <<'EOF'
carp_interface=vtnet0
auto=1
node_alpha_nodename=alpha
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_alpha_heir2=charlie
node_alpha_vhid=1
node_alpha_vhid_ip=192.0.2.101/32
node_bravo_nodename=bravo
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=charlie
node_bravo_heir2=alpha
node_bravo_vhid=2
node_bravo_vhid_ip=192.0.2.102/32
node_bravo_auto_promote=alpha
node_charlie_nodename=charlie
node_charlie_mgmt=charlie-mgmt.example.net
node_charlie_heir=alpha
node_charlie_heir2=bravo
node_charlie_vhid=3
node_charlie_vhid_ip=192.0.2.103/32
EOF

if ! conf_load "${CONF}"; then
    t_plan 1
    t_not_ok "the fixture configuration loads"
    t_done
fi
adapter_init > /dev/null 2>&1 || true

# good_world  -- rc.conf, sysctls and devd rules that all agree with what
# seance renders, so that each fixture below breaks exactly one thing.
good_world()
{
    # The trailing comment is stripped, because rc.conf(5) is sourced by sh(1)
    # and sysrc(8) reports the VALUE: a fixture that left the comment inside
    # the quotes would be asserting against a string no node ever has.
    carp_render_rc bravo |
        awk '/^ifconfig_/ { sub(/[ \t]*#.*$/, ""); print "/etc/rc.conf: " $0 }' \
        > "${WORK}/rcvars"
    printf '/etc/rc.conf: kld_list="carp"\n' >> "${WORK}/rcvars"

    {
        printf 'net.inet.carp.allow 1\n'
        printf 'net.inet.carp.preempt 1\n'
    } > "${WORK}/sysctls"

    {
        printf 'net.inet.carp.allow=1\n'
        printf 'net.inet.carp.preempt=1\n'
    } > "${CARP_SYSCTL_CONF}"

    printf 'carp_load="YES"\n' > "${CARP_LOADER_CONF}"

    carp_render_devd bravo > "${CARP_DEVD_PREFERRED}"
    rm -f "${CARP_DEVD_ALSO}"

    repl_cron_line > "${VERIFY_CRON_PREFERRED}"
    rm -f "${VERIFY_CRON_ALSO}"
}

# check <verify-function> [arg]  -- run one check and capture what it said.
#
# COUNTED FROM THE OUTPUT, not from VERIFY_FAIL. The check runs inside a
# command substitution, so every increment it makes to the library's counters
# happens in a subshell and is gone by the time an assertion could read it: a
# row asserting VERIFY_FAIL was 0 would pass whatever the check found, which is
# the vacuous-assertion trap the M2 loop's angle (g) recorded. The lines are
# the verdict.
CHECK_OUT=""
check()
{
    CHECK_OUT=$( "$@" 2>&1 )
}

# fails  -- how many FAIL lines the last check printed.
fails()
{
    printf '%s\n' "${CHECK_OUT}" | awk '/^FAIL /{ n++ } END { print n + 0 }'
}

t_plan 35

# ---------------------------------------------------------------------------
# 1. The rendering is a function of the configuration and nothing else
# ---------------------------------------------------------------------------

for what in cron carp devd; do
    A=$( verify_render "${what}" 2>/dev/null )
    B=$( verify_render "${what}" 2>/dev/null )
    t_is "${A}" "${B}" \
        "verify --render ${what} renders the same bytes twice"

    # The environment a cron job runs under is not the environment an operator
    # rendered from, and the timestamps in this project are UTC-always by spec
    # (TESTING.md §3).
    TZ="Pacific/Auckland"
    LC_ALL="C"
    export TZ LC_ALL
    C=$( verify_render "${what}" 2>/dev/null )
    TZ="UTC"
    LC_ALL="en_US.UTF-8"
    export TZ LC_ALL
    D=$( verify_render "${what}" 2>/dev/null )
    unset TZ LC_ALL

    t_is "${C}" "${D}" \
        "and the same bytes under another TZ and another locale (${what})"
    t_is "${A}" "${C}" \
        "which are the bytes it renders here too (${what})"
done

# Positive controls: the rendering has to be the thing the checks below are
# about, or a byte-stable empty string would satisfy all six rows above.
CARPRENDER=$( verify_render carp )
t_like "${CARPRENDER}" 'vhid 1 advskew 100' \
    "the carp rendering carries alpha's vhid at the heir's advskew"
DEVDRENDER=$( verify_render devd )
# shellcheck disable=SC2016
#   The single quotes are the point: $subsystem is devd(8)'s own variable in
#   the rendered rule, not an expansion for this shell.
t_like "${DEVDRENDER}" 'promote-event \$subsystem' \
    "and the devd rendering runs promote-event on the subsystem devd supplies"

# THE RENDERING OWNS NOTHING BUT ITS ALIASES (D-179, the owner's finding on
# the fleet). Its documented use is appending to rc.conf, rc.conf is shell,
# and the last assignment wins -- so a rendered kld_list line, appended to a
# node whose kld_list already loads vmm and if_bridge, would silently drop
# both at the next boot. The rendering may assign ifconfig_<if>_alias<n>
# variables and NOTHING else.
t_unlike "${CARPRENDER}" '^kld_list=' \
    "the carp rendering assigns no kld_list -- an appended assignment would replace the node's list"
t_is "$( printf '%s\n' "${CARPRENDER}" | grep -c '^[A-Za-z_][A-Za-z0-9_]*=' | tr -d ' ' )" \
    "$( printf '%s\n' "${CARPRENDER}" | grep -c '^ifconfig_' | tr -d ' ' )" \
    "and every assignment it makes is an ifconfig_<if>_alias<n>"

# AND ITS INDICES ARE OBSERVED, NOT ASSUMED. This world's rcvars carry no
# aliases, so the rendering starts at alias0; give the node two existing
# aliases of its own and the same rendering must start after them -- an index
# that collided would redefine the node's alias with the same last-wins
# semantics as the kld_list line above.
t_like "${CARPRENDER}" 'ifconfig_vtnet0_alias0=' \
    "with no existing aliases the rendering starts at alias0"
cp "${WORK}/rcvars" "${WORK}/rcvars.drill"
printf '/etc/rc.conf: ifconfig_vtnet0_alias0="inet 192.0.2.10/24"\n' >> "${WORK}/rcvars"
printf '/etc/rc.conf: ifconfig_vtnet0_alias1="inet 192.0.2.11/24"\n' >> "${WORK}/rcvars"
CARPRENDER2=$( verify_render carp )
t_like "${CARPRENDER2}" 'ifconfig_vtnet0_alias2=' \
    "two existing aliases move the rendering's first index to alias2"
t_unlike "${CARPRENDER2}" 'ifconfig_vtnet0_alias[01]=' \
    "and it assigns neither of the indices the node already owns"
mv "${WORK}/rcvars.drill" "${WORK}/rcvars"
t_unlike "${DEVDRENDER}" '"2@vtnet0"' \
    "and has no rule for this node's OWN vhid, which is what a boot looks like (D-121)"

# ---------------------------------------------------------------------------
# 2. Drift: carp
# ---------------------------------------------------------------------------

good_world
check verify_carp bravo
t_is "$( fails )" "0" \
    "a node whose rc.conf, sysctls and interfaces agree with the rendering has no carp failures"

good_world
sed -e 's/advskew 100/advskew 50/' "${WORK}/rcvars" > "${WORK}/rcvars.new"
mv "${WORK}/rcvars.new" "${WORK}/rcvars"
check verify_carp bravo
t_like "${CHECK_OUT}" 'FAIL carp: ifconfig_vtnet0_alias[0-9]+ carries vhid 1 but not what seance expects' \
    "an advskew somebody edited by hand is a FAIL naming the variable"
t_like "${CHECK_OUT}" 'expected:.*advskew 100' \
    "and the failure prints what was expected beside what is installed"

good_world
grep -v 'vhid 1 ' "${WORK}/rcvars" > "${WORK}/rcvars.new"
mv "${WORK}/rcvars.new" "${WORK}/rcvars"
check verify_carp bravo
t_like "${CHECK_OUT}" 'FAIL carp: no ifconfig_vtnet0_alias<n> carries vhid 1' \
    "a vhid with no alias at all is a FAIL"
t_like "${CHECK_OUT}" 'will never learn that alpha has died' \
    "and it says what the node has therefore stopped being able to do"

good_world
sed -e 's/^net.inet.carp.preempt 1/net.inet.carp.preempt 0/' "${WORK}/sysctls" \
    > "${WORK}/sysctls.new"
mv "${WORK}/sysctls.new" "${WORK}/sysctls"
check verify_carp bravo
t_like "${CHECK_OUT}" 'FAIL carp: net\.inet\.carp\.preempt is 0, not 1' \
    "preempt turned off is a FAIL, not a warning (D-116)"
t_like "${CHECK_OUT}" 'sysctl net\.inet\.carp\.preempt=1' \
    "and the failure carries the command that fixes it"

good_world
grep -v 'preempt' "${CARP_SYSCTL_CONF}" > "${CARP_SYSCTL_CONF}.new"
mv "${CARP_SYSCTL_CONF}.new" "${CARP_SYSCTL_CONF}"
check verify_carp bravo
t_is "$( fails )" "0" \
    "a node that is right now and wrong after a reboot has not failed yet"
t_like "${CHECK_OUT}" "WARN carp: ${CARP_SYSCTL_CONF} does not set net\.inet\.carp\.preempt" \
    "-- it is a WARN about persistence, and it names the file"

# ---------------------------------------------------------------------------
# 3. Drift: devd
# ---------------------------------------------------------------------------

good_world
check verify_devd bravo
t_is "$( fails )" "0" \
    "the rules seance rendered are the rules seance recognises"
t_like "${CHECK_OUT}" 'PASS devd: .* runs \[' \
    "and it says which action it found"

good_world
sed -e 's#'"${SHIM}"'/pretend-platform seance#/usr/local/bin/seance#' \
    "${CARP_DEVD_PREFERRED}" > "${CARP_DEVD_PREFERRED}.new"
mv "${CARP_DEVD_PREFERRED}.new" "${CARP_DEVD_PREFERRED}"
check verify_devd bravo
t_like "${CHECK_OUT}" 'FAIL devd: .* does not run \[' \
    "a rule that runs some other seance is a FAIL"
t_like "${CHECK_OUT}" 'whatever it does run, it is not this node' \
    "and it says so in those words, because the file looks right"

good_world
grep -v '"1@vtnet0"' "${CARP_DEVD_PREFERRED}" > "${CARP_DEVD_PREFERRED}.new"
mv "${CARP_DEVD_PREFERRED}.new" "${CARP_DEVD_PREFERRED}"
check verify_devd bravo
t_like "${CHECK_OUT}" 'FAIL devd: .* has no rule for vhid 1 \(alpha\)' \
    "a missing rule for a node this one is ARMED for is a FAIL"
t_like "${CHECK_OUT}" 'armed for a death it will never hear about' \
    "and names the consequence rather than the diff"

# ---------------------------------------------------------------------------
# 4. Drift: cron
# ---------------------------------------------------------------------------

good_world
check verify_cron
t_like "${CHECK_OUT}" "PASS cron: ${VERIFY_CRON_PREFERRED} carries the expected line" \
    "the rendered crontab line is the line verify looks for"

good_world
printf '*/5 * * * * root /usr/local/bin/seance repl\n' > "${VERIFY_CRON_PREFERRED}"
check verify_cron
t_like "${CHECK_OUT}" 'WARN cron: .* does not carry the expected line' \
    "a fragment somebody rewrote is a WARN"
t_like "${CHECK_OUT}" 'expected:.*seance repl' \
    "and the expected line is printed, so the operator can see the difference"

t_done
