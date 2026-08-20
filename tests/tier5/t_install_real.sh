#!/bin/sh
# Tier 5, stage "install" -- docs/INSTALL.md, followed literally, on a real
# CBSD node, by something that is not the person who wrote it.
#
# WHY THIS FILE EXISTS. Every other tier drives seance from a checkout, with
# SEANCE_CONF and SEANCE_STATE_DIR in the environment, through a wrapper the
# harness put on PATH. An operator does none of that: they clone the module
# into place, add a line to modules.conf, re-run initenv, and then type the
# commands README and docs/INSTALL.md print. Nothing in this repository had
# ever taken that path, and the first time it was taken -- at M5, in the reaper
# guest -- it produced four defects in a row, three of them in the shipped
# product and all four of the same class:
#
#   * rc.d/seance_gate resolved the platform's verb symlink and then walked
#     PAST it to bin/seance, which rc(8) cannot run: "no config file", exit 2,
#     and the unit's own diagnostic saying THE ESTATE HAS NOT BEEN GATED. The
#     resurrection gate did not run on any node it was installed on;
#   * `verify --render cron` rendered a line naming bin/seance, which cron
#     cannot run either -- so a freshly installed node replicated nothing, for
#     ever, while `verify` reported the crontab line as correctly installed;
#   * README and docs/INSTALL.md §4 told the operator to link bin/seance onto
#     the mesh's PATH, so `ssh <peer> seance placement` exits 2 and every peer
#     reads as a node that COULD NOT REPORT -- the gate withholding whole
#     estates, `promote` aborting and `failback` refusing, fleet-wide, from an
#     install instruction (D-96's failure mode, delivered by the manual);
#   * `/usr/local/etc/cron.d` does not exist on a stock FreeBSD node, so the
#     redirect the docs and `verify`'s own remedy line print fails with
#     "No such file or directory" and installs nothing.
#
# The common cause is one sentence: bin/seance is the plain dispatcher and
# learns which node it is on only from what the module's verb wrapper exports
# (D-2), and three places told the platform to run it directly. `verify
# --render devd` did not, because D-117 had already worked this out for devd --
# which is the reason the fix is "use adapter_fact verb" and not four
# unrelated patches.
#
# WHAT STANDS IN FOR `git clone`. The reaper guest has no git (charter,
# environment facts), so the clone is a tar of the same tree into the same
# path. What the clone is being relied on to produce is a REAL DIRECTORY
# containing the repository root, and that is what is asserted; the git command
# itself is not what this stage is about.
#
# WHAT THIS COSTS. One CBSD node (shapeb, about 19 s) plus two initenv runs,
# and it writes outside $REAPER_STATE -- /usr/local/cbsd/modules/seance.d,
# /usr/local/bin/seance, /usr/local/etc/rc.d/seance_gate,
# /usr/local/etc/cron.d/seance -- which `reaper reset` does not roll back. Each
# is registered with t_at_exit BEFORE it is created, and the last section
# asserts the uninstall procedure removed the platform's half of it.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../shapeb/lib/shapeb.subr
. "${T_ROOT}/tests/shapeb/lib/shapeb.subr"

if [ "$( id -u )" -ne 0 ]; then
    t_diag "shape B builds a real CBSD node; it needs root"
    echo "t_install_real: must run as root" >&2
    exit 2
fi

# The paths docs/INSTALL.md names, spelled once. CIX_DISTDIR is /usr/local/cbsd
# on every CBSD installation from packages (docs/cbsd-module-notes.md §1); the
# document hard-codes it too, and a stage that derived it from the adapter
# would be following a different procedure from the one being checked.
DISTDIR="/usr/local/cbsd"
MODDIR="${DISTDIR}/modules/seance.d"
PATHLINK="/usr/local/bin/seance"
RCUNIT="/usr/local/etc/rc.d/seance_gate"
CRONDIR="/usr/local/etc/cron.d"
CRONFILE="${CRONDIR}/seance"

WORK=$( t_tmpdir )

# cbsd_seance <args...>  -- the way an operator invokes it: through the
# platform, from a directory with no CBSDfile in it (D-48).
cbsd_seance()
{
    ( cd /var/empty || exit 2; NOCOLOR=1 export NOCOLOR; exec cbsd seance "$@" )
}

# cron_env <command...>  -- run a command with EXACTLY the environment cron(8)
# gives a job and nothing else. This is the whole point of two assertions
# below: a command that works from an interactive root shell and not from here
# is a command that will never run.
cron_env()
{
    env -i PATH=/usr/bin:/bin HOME=/root LOGNAME=root USER=root SHELL=/bin/sh "$@"
}

# login_env <command...>  -- and the environment an ssh session gets, which is
# the login PATH and no more. The mesh link is reached this way.
login_env()
{
    env -i PATH=/sbin:/bin:/usr/sbin:/usr/bin:/usr/local/sbin:/usr/local/bin \
        HOME=/root LOGNAME=root USER=root SHELL=/bin/sh "$@"
}

# shellcheck disable=SC2329
#   Invoked indirectly: t_at_exit registers it with the harness's EXIT trap.
install_cleanup()
{
    rm -f "${PATHLINK}" "${CRONFILE}" "${RCUNIT}"
    rmdir "${CRONDIR}" 2> /dev/null
    sysrc -x seance_gate_enable > /dev/null 2>&1
    rm -rf "${MODDIR}"
    return 0
}

shapeb_up
up_rc=$?
if [ "${up_rc}" -ne 0 ]; then
    t_plan 1
    t_not_ok "the shape-B substrate came up"
    t_diag "shapeb_up exited ${up_rc}"
    t_done
fi

# Armed before the first thing that writes outside the reset dataset.
t_at_exit install_cleanup

WD=$( shapeb_workdir )

t_plan 43

# ---------------------------------------------------------------------------
# INSTALL.md §1 -- the clone
# ---------------------------------------------------------------------------

t_rc 0 "the directory INSTALL.md clones into exists" -- test -d "${DISTDIR}/modules"
t_rc 1 "and seance is not installed there yet: this is a clean node" -- \
    test -e "${MODDIR}"

mkdir -p "${MODDIR}"
( cd "${T_ROOT}" && tar cf - --exclude ./out --exclude ./.git . ) |
    ( cd "${MODDIR}" && tar xf - )

# INSTALL.md's one warning about the clone: `cbsd module mode=list` enumerates
# modules with find -type d, so a symlinked module directory is invisible to
# it even though every verb works.
if [ -d "${MODDIR}" ] && [ ! -L "${MODDIR}" ]; then
    t_ok "the module directory is a real directory and not a symlink"
else
    t_not_ok "the module directory is a real directory and not a symlink"
fi

for f in metadata.conf securecmd seance bin/seance VERSION; do
    t_rc 0 "the clone carries ${f}" -- test -e "${MODDIR}/${f}"
done

# ---------------------------------------------------------------------------
# INSTALL.md §1 -- enable it, and initialise
# ---------------------------------------------------------------------------

echo seance.d >> "${WD}/etc/modules.conf"
t_like "$( cat "${WD}/etc/modules.conf" )" '^seance\.d$' \
    "the modules.conf line is there, one name per line"

# The unattended form, verbatim from INSTALL.md §1. No preseed, no workdir=:
# the node was initialised once already and cbsd_workdir is in rc.conf, which
# is exactly the state an operator adding a module is in.
env NOINTER=1 ALWAYS_YES=1 /usr/local/cbsd/sudoexec/initenv \
    < /dev/null > "${WORK}/initenv.log" 2>&1
INITENV_RC=$?
if [ "${INITENV_RC}" -eq 0 ]; then
    t_ok "the unattended initenv form INSTALL.md gives exits 0"
else
    t_not_ok "the unattended initenv form INSTALL.md gives exits 0"
    t_diag "exit ${INITENV_RC}"
    sed -e 's/^/# /' "${WORK}/initenv.log"
fi

t_like "$( cat "${WORK}/initenv.log" )" 'Installing module seance\.d' \
    "and stage 8 says it installed the module"

# The symlink is the whole of the installation as far as the platform is
# concerned -- and it points at the module's VERB WRAPPER, which is what
# carries this node's facts into the dispatcher (D-2).
t_rc 0 "the platform planted a verb symlink" -- test -L "${WD}/modules/seance"
t_is "$( readlink "${WD}/modules/seance" )" "${MODDIR}/seance" \
    "and it points at the module's verb wrapper, not at bin/seance"
t_like "$( cat "${WD}/nc.inventory" )" 'mod_seance_enabled="YES"' \
    "the inventory records the module as enabled"

# ---------------------------------------------------------------------------
# INSTALL.md §1 -- confirm the module is live
# ---------------------------------------------------------------------------

t_rc 0 "cbsd seance version exits 0" -- cbsd_seance version
t_stdout_is "seance $( cat "${MODDIR}/VERSION" )" \
    "and prints the version the module carries" -- cbsd_seance version

t_like "$( ( cd /var/empty && NOCOLOR=1 cbsd help 2>&1 ) )" 'seance' \
    "cbsd help lists the verb, which is how an operator finds it"

# ---------------------------------------------------------------------------
# The first configuration -- setup's headless half, which is the one an
# install is driven from
# ---------------------------------------------------------------------------
#
# The default target is $SEANCE_CBSD_WORKDIR/etc/seance.conf (D-3), and the
# wrapper is what sets that variable -- so where this file lands is itself a
# check that the wrapper did its job. The fleet is the fictional ring the
# sample documents, with alpha named as THIS node so that the node recognises
# itself (D-4).

cbsd_seance setup --non-interactive \
    --set node_alpha_nodename="${SHAPEB_NODE}" \
    --set node_alpha_mgmt=alpha-mgmt.example.net \
    --set node_alpha_heir=bravo \
    --set node_alpha_heir2=charlie \
    --set node_bravo_nodename=bravo \
    --set node_bravo_mgmt=bravo-mgmt.example.net \
    --set node_bravo_heir=charlie \
    --set node_bravo_heir2=alpha \
    --set node_charlie_nodename=charlie \
    --set node_charlie_mgmt=charlie-mgmt.example.net \
    --set node_charlie_heir=alpha \
    --set node_charlie_heir2=bravo \
    > "${WORK}/setup.out" 2>&1
SETUP_RC=$?
if [ "${SETUP_RC}" -eq 0 ]; then
    t_ok "seance setup --non-interactive writes a first configuration"
else
    t_not_ok "seance setup --non-interactive writes a first configuration"
    sed -e 's/^/# /' "${WORK}/setup.out"
fi

t_rc 0 "and it landed at the default target the wrapper's workdir names" -- \
    test -r "${WD}/etc/seance.conf"

t_stdout_is "PASS" "seance config --check passes on what setup wrote" -- \
    cbsd_seance config --check

# ---------------------------------------------------------------------------
# INSTALL.md §6 -- the cron line
# ---------------------------------------------------------------------------

VERIFY_BEFORE=$( cbsd_seance verify 2>&1 )

t_like "${VERIFY_BEFORE}" 'install it with:  mkdir -p /usr/local/etc/cron\.d' \
    "verify's remedy line creates the directory it is about to redirect into"

CRON=$( cbsd_seance verify --render cron )
t_like "${CRON}" '^\*/[0-9]+ \* \* \* \* root ' \
    "verify --render cron renders a crontab(5) system line"
t_unlike "${CRON}" 'bin/seance' \
    "and it does not name bin/seance, which cron cannot run"

# THE ASSERTION THIS SECTION IS FOR. Not that the line looks right: that the
# command in it runs, with the environment cron will really give it.
# Splitting the line is how the command in it is reached -- and `set -f`
# first, because four of the five time fields are literal asterisks and the
# shell would otherwise glob them against the working directory. (Observed:
# without it the "command" became this repository's file list, and the row
# failed with `env: VERSION: No such file or directory` -- which is the row
# doing its job on the test rather than on the product.)
set -f
# shellcheck disable=SC2086
#   Deliberate word splitting: a crontab(5) line is five time fields, a user
#   name and then the command, and splitting it is how the command is reached.
set -- ${CRON}
set +f
shift 6
cron_env "$@" > "${WORK}/cron.out" 2>&1
CRONRUN_RC=$?
t_unlike "$( cat "${WORK}/cron.out" )" 'no config file' \
    "the rendered command runs under cron's own environment, and finds its configuration"
if [ "${CRONRUN_RC}" -eq 0 ] || [ "${CRONRUN_RC}" -eq 1 ]; then
    t_ok "and exits with a replication verdict (${CRONRUN_RC}), not a contract error"
else
    t_not_ok "and exits with a replication verdict (${CRONRUN_RC}), not a contract error"
    sed -e 's/^/# /' "${WORK}/cron.out"
fi

mkdir -p "${CRONDIR}"
cbsd_seance verify --render cron > "${CRONFILE}"
t_like "$( cbsd_seance verify 2>&1 )" "PASS cron: ${CRONFILE} carries the expected line" \
    "installed as documented, verify's cron check passes"

# ---------------------------------------------------------------------------
# INSTALL.md §4 -- the mesh link
# ---------------------------------------------------------------------------

ln -sf "${MODDIR}/seance" "${PATHLINK}"
login_env seance placement > "${WORK}/place.out" 2>&1
PLACE_RC=$?
if [ "${PLACE_RC}" -eq 0 ]; then
    t_ok "the link INSTALL.md §4 names answers 'seance placement' over a login PATH"
else
    t_not_ok "the link INSTALL.md §4 names answers 'seance placement' over a login PATH"
    t_diag "exit ${PLACE_RC}"
    sed -e 's/^/# /' "${WORK}/place.out"
fi
t_like "$( cat "${WORK}/place.out" )" '^placement: ' \
    "and its last word is a placement verdict, which is what a peer reads"

# The mutation, run rather than reasoned: the instruction as it was written
# before M5. It must NOT answer -- and the way it fails is the way that made
# every peer read as silent.
ln -sf "${MODDIR}/bin/seance" "${PATHLINK}"
login_env seance placement > "${WORK}/place-bad.out" 2>&1
t_rc 2 "the pre-M5 link to bin/seance does not answer at all" -- \
    login_env seance placement
t_like "$( cat "${WORK}/place-bad.out" )" 'no config file' \
    "and says why: the plain dispatcher is not told which node it is on"
ln -sf "${MODDIR}/seance" "${PATHLINK}"

# ---------------------------------------------------------------------------
# INSTALL.md §5 -- the boot gate, and `service seance_gate onestart`
# ---------------------------------------------------------------------------

cp "${MODDIR}/rc.d/seance_gate" "${RCUNIT}"
sysrc seance_gate_enable=YES > /dev/null

service seance_gate onestart > "${WORK}/gate.out" 2>&1
GATE_RC=$?

# No peer of this one-node lab answers, so the fail-safe fires and the whole
# estate is withheld: exit 1 with a HELD line per guest is the PASS here, and
# exit 0 would mean it found peers that do not exist.
t_is "${GATE_RC}" "1" \
    "service seance_gate onestart runs the gate and reports guests withheld"
t_unlike "$( cat "${WORK}/gate.out" )" 'THE ESTATE HAS NOT BEEN GATED' \
    "and NOT 'the gate could not run', which is what rc(8) got until M5"
t_like "$( cat "${WORK}/gate.out" )" 'HELD' \
    "the unit's output is the gate's own"

# Read from the platform's database rather than from the unit's exit code: what
# matters is that the guests really are withheld.
JLS=$( ( cd /var/empty && NOCOLOR=1 cbsd jls header=0 display=jname,status ) )
if printf '%s\n' "${JLS}" | awk -v j="${SHAPEB_JAIL}" '$1 == j && $2 == "Slave"' |
    grep -q .
then
    t_ok "and the estate is withheld in the platform's own database"
else
    t_not_ok "and the estate is withheld in the platform's own database"
    printf '%s\n' "${JLS}" | sed -e 's/^/# /'
fi

# ---------------------------------------------------------------------------
# INSTALL.md §8 -- check the whole node
# ---------------------------------------------------------------------------

STATUS=$( cbsd_seance status 2>&1 )
t_like "${STATUS}" "guest ${SHAPEB_JAIL}" \
    "cbsd seance status names the guests this node really has"
t_like "$( printf '%s\n' "${STATUS}" | tail -1 )" '^status: ' \
    "and its last line is a verdict"

# ---------------------------------------------------------------------------
# INSTALL.md §3 -- uninstall
# ---------------------------------------------------------------------------

grep -v '^seance\.d$' "${WD}/etc/modules.conf" > "${WORK}/modules.conf"
cp "${WORK}/modules.conf" "${WD}/etc/modules.conf"

env NOINTER=1 ALWAYS_YES=1 /usr/local/cbsd/sudoexec/initenv \
    < /dev/null > "${WORK}/initenv-remove.log" 2>&1

t_rc 1 "the uninstall procedure removes the verb symlink" -- \
    test -e "${WD}/modules/seance"
t_like "$( cat "${WD}/nc.inventory" )" 'mod_seance_enabled="NO"' \
    "and clears the inventory flag"

# INSTALL.md's own promise: initenv does not delete data, and neither does the
# procedure. An uninstall that took the configuration with it would be an
# uninstall nobody could undo.
t_rc 0 "and leaves this node's configuration alone" -- \
    test -r "${WD}/etc/seance.conf"

# ---------------------------------------------------------------------------
# Teardown, asserted (4)
# ---------------------------------------------------------------------------

shapeb_down_and_check

t_done
