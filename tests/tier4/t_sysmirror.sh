#!/bin/sh
# Tier 4 -- the configuration mirror (decision D-82).
#
# A jail's registerable configuration lives in ${jailsysdir}/<n>/, which is a
# plain directory on CBSD's workdir dataset and is outside the guest's own
# dataset -- so nothing replicates it, and a survivor would have the guest's
# data and no way to register it. seance carries it in one extra dataset per
# node, mirrored before every tick and replicated like a guest.
#
# Most of that is testable here with no ZFS at all: the mirror is a directory
# copy with a prune, and the prune is the half that can quietly stop working.
# The parts that do need a pool are driven against a scripted `zfs` on PATH,
# the same way tests/tier4/t_adapter_parse.sh drives the adapter's resolution.
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
# shellcheck source=../../lib/zfs.subr
. "${T_ROOT}/lib/zfs.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/repl.subr
. "${T_ROOT}/lib/repl.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../mock-adapter.subr
. "${T_ROOT}/tests/mock-adapter.subr"

SEANCE_TMP_REGISTRY=$( t_tmpdir )/registry
: > "${SEANCE_TMP_REGISTRY}"
export SEANCE_TMP_REGISTRY
t_at_exit 'seance_tmp_cleanup'

t_plan 18

# ---------------------------------------------------------------------------
# The mirror itself: a directory copy that DELETES, which is the half that
# quietly stops working
# ---------------------------------------------------------------------------

SRC=$( t_tmpdir )/src
DST=$( t_tmpdir )/dst
mkdir -p "${SRC}/hooks"
printf 'name=web01\n' > "${SRC}/rc.conf_web01"
printf 'a hook\n' > "${SRC}/hooks/master_prestart"
ln -s rc.conf_web01 "${SRC}/current"

t_rc 0 "the mirror copies a configuration directory" \
    -- repl_sys_mirror "${SRC}" "${DST}"
t_is "$( cat "${DST}/rc.conf_web01" )" "name=web01" "the file came across"
t_is "$( cat "${DST}/hooks/master_prestart" )" "a hook" "and so did the subdirectory"
t_rc 0 "and a symlink stayed a symlink (cp -a is -pPR)" -- test -h "${DST}/current"

# The prune. A hook the operator deleted must not survive on the mirror, or a
# promotion would run it on the survivor.
rm -f "${SRC}/hooks/master_prestart"
printf 'name=web01\nastart=1\n' > "${SRC}/rc.conf_web01"

t_rc 0 "a second mirror of a changed directory" \
    -- repl_sys_mirror "${SRC}" "${DST}"
t_rc 1 "a file deleted at the source is deleted on the mirror" \
    -- test -e "${DST}/hooks/master_prestart"
t_rc 0 "and the directory that held it survived, because the source still has it" \
    -- test -d "${DST}/hooks"
t_is "$( cat "${DST}/rc.conf_web01" )" "name=web01
astart=1" "a changed file is replaced, not appended to"

# A directory deleted at the source goes whole.
rm -rf "${SRC}/hooks"
repl_sys_mirror "${SRC}" "${DST}" || t_diag "the third mirror failed"
t_rc 1 "a directory deleted at the source is deleted on the mirror" \
    -- test -e "${DST}/hooks"

t_rc 1 "mirroring from a source that does not exist is a failure, not an empty mirror" \
    -- repl_sys_mirror "${SRC}/nope" "${DST}"
t_rc 1 "and a relative destination is refused before anything is removed" \
    -- repl_sys_mirror "${SRC}" "relative/path"

# ---------------------------------------------------------------------------
# Where the mirror lives
# ---------------------------------------------------------------------------

ZBIN=$( t_tmpdir )/bin
mkdir -p "${ZBIN}"
cat > "${ZBIN}/zfs" <<'EOF'
#!/bin/sh
# The three questions the mirror asks a pool, answered from ZFS_WORLD:
# "<dataset><TAB><mountpoint>", with path resolution by longest mountpoint
# prefix, exactly as the real thing does it.
set -u
w=${ZFS_WORLD}
case "$*" in
    "list -H -o name -t filesystem,volume -r "*)
        d=${*##* }
        awk -F '\t' -v d="${d}" '$1 == d || index($1, d "/") == 1 { print $1 }' "${w}" |
            grep . || exit 1
        exit 0
        ;;
    "get -H -o value mountpoint "*)
        d=${*##* }
        awk -F '\t' -v d="${d}" '$1 == d { print $2; f = 1 } END { exit !f }' "${w}" || exit 1
        exit 0
        ;;
    "list -H -o name "*)
        a=${*##* }
        case "${a}" in
            /*)
                awk -F '\t' -v p="${a}" '
                    $2 == "none" || $2 == "-" { next }
                    $2 == p || index(p, $2 "/") == 1 {
                        if (length($2) > best) { best = length($2); n = $1 }
                    }
                    END { if (n == "") { exit 1 } ; print n }
                ' "${w}" || exit 1
                ;;
            *)
                awk -F '\t' -v d="${a}" '$1 == d { print $1; f = 1 } END { exit !f }' "${w}" ||
                    exit 1
                ;;
        esac
        exit 0
        ;;
esac
echo "zfs: this fixture does not answer: $*" >&2
exit 2
EOF
chmod 0755 "${ZBIN}/zfs"

ZWORLD=$( t_tmpdir )/world
WD=$( t_tmpdir )/workdir
mkdir -p "${WD}/jails-system/web01" "${WD}/jails-data"
# The guests are named the way CBSD names them: ZPOOL is the dataset that
# CONTAINS jails-data (sudoexec/mkdatadir:20) and a guest is its child, so a
# workdir dataset of pool0/cbsd gives guests at pool0/cbsd/<name>. The mirror
# has to land beside them, and getting that wrong would put it in a pool that
# is not the one the guests are in.
cat > "${ZWORLD}" <<EOF
pool0/cbsd	${WD}
pool0/cbsd/web01	${WD}/jails-data/web01-data
pool0/cbsd/db01	${WD}/vm/db01
EOF

MOCK_POOL=pool0/cbsd

ZFS_WORLD=${ZWORLD}
export ZFS_WORLD
PATH="${ZBIN}:${PATH}"
export PATH

SEANCE_MOCK_WORKDIR=${WD}
SEANCE_STATE_DIR=$( t_tmpdir )/state
export SEANCE_MOCK_WORKDIR SEANCE_STATE_DIR

t_is "$( repl_sys_dataset )" "pool0/cbsd/${REPL_SYS_GUEST}" \
    "the mirror is a child of the dataset that holds jails-data, beside the guests"
t_is "$( repl_sys_mountpoint )" "${SEANCE_STATE_DIR}/sys" \
    "and it is mounted inside the state directory, which is seance's own"

# ---------------------------------------------------------------------------
# Which guests need mirroring, and which already travel
# ---------------------------------------------------------------------------

# A jail: CBSD keeps its configuration in ${jailsysdir}/<n>, which is not under
# any of the guest's own dataset mountpoints. It has to be carried.
t_rc 1 "a jail's configuration does NOT travel inside its own datasets" \
    -- repl_sys_travels web01

# A VM: ${jailsysdir}/<n> is a symlink to ${workdir}/vm/<n>, which IS the
# guest's dataset mountpoint (sudoexec/bcreate:599). It travels already.
mkdir -p "${WD}/vm/db01"
ln -sf "${WD}/vm/db01" "${WD}/jails-system/db01"
t_rc 0 "a VM's configuration DOES travel, because the platform symlinked it into the dataset" \
    -- repl_sys_travels db01

# ---------------------------------------------------------------------------
# The seam that lets the mirror ride the guest machinery
# ---------------------------------------------------------------------------

cat >> "${ZWORLD}" <<EOF
pool0/cbsd/${REPL_SYS_GUEST}	${SEANCE_STATE_DIR}/sys
EOF

t_is "$( repl_guest_datasets "${REPL_SYS_GUEST}" )" "pool0/cbsd/${REPL_SYS_GUEST}" \
    "repl asks for the mirror's datasets and gets the mirror"
t_is "$( repl_guest_datasets web01 )" "$( adapter_guest_datasets web01 )" \
    "and for a guest's, and gets the adapter's answer unchanged"

# The replica path falls out of the machinery rather than being a second rule:
# <standby_root>/<home>/<basename>, which for the mirror is exactly what D-82
# says it should be.
t_is "$( repl_replica_root "tank/standby" "alpha" "pool0/cbsd/${REPL_SYS_GUEST}" )" \
    "tank/standby/alpha/${REPL_SYS_GUEST}" \
    "the mirror lands at <standby_root>/<home>/seance-sys, by the same rule as a guest"

t_done
