#!/bin/sh
# The rediscovery battery (TESTING.md §8).
#
#   sh tests/rediscovery/run.sh --tier 6
#
# For each row of table.tsv belonging to the named tier: copy the repository to
# a scratch directory, apply the patch that REVERTS one protection, run the
# named test there, and require it to FAIL. A protection whose removal changes
# nothing is not a protection.
#
# The working tree is never touched. Every patch is applied to a copy, and the
# copy is destroyed whether the run passed, failed or died -- which is why
# "restore" is not a step: there is nothing to restore.
#
# --tier is required rather than defaulted, because tier 6 needs root, ZFS and
# vnet jails and takes minutes per row. This is not a suite that runs on every
# edit; it is the acceptance test for the harness itself, run before a
# milestone is trusted. Nothing invokes it automatically.
#
# THE FALSE-PASS TRAP: this runner asserts a FAILURE, so every way of not
# running the test at all looks like success. Each row therefore checks, in
# order, that the patch applied, that the test file exists in the copy, and
# that the run produced assertions -- before it is willing to call a non-zero
# exit a rediscovery.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

ROOT=$( cd "$( dirname "$( realpath "$0" )" )/../.." && pwd )
HERE="${ROOT}/tests/rediscovery"
TABLE="${HERE}/table.tsv"

TAB=$( printf '\t.' )
TAB=${TAB%.}

usage()
{
    cat <<EOF
usage: sh tests/rediscovery/run.sh --tier <n>

Reverts each protection listed in tests/rediscovery/table.tsv for that tier and
requires the named test to fail. Needs whatever the tier needs: tier 6 is root,
ZFS and vnet jails, inside a reaper session.

Exit 0 when every protection was rediscovered, 1 when any was not, 2 on a usage
or contract error.
EOF
}

TIER=""

while [ $# -gt 0 ]; do
    case "$1" in
        --tier)
            [ $# -ge 2 ] || { usage >&2; exit 2; }
            TIER=$2
            shift
            ;;
        --tier=*) TIER=${1#--tier=} ;;
        -h|--help) usage; exit 0 ;;
        *) echo "rediscovery: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

case "${TIER}" in
    ''|*[!0123456789]*) echo "rediscovery: --tier <n> is required" >&2; exit 2 ;;
esac

[ -r "${TABLE}" ] || { echo "rediscovery: no table at ${TABLE}" >&2; exit 2; }

# rows <tier>  -- the data rows for one tier: comments, the header and other
# tiers dropped.
rows()
{
    awk -F "${TAB}" -v t="$1" '
        /^#/     { next }
        NF < 4   { next }
        $1 == "patch-file" { next }
        $2 == t  { print }
    ' "${TABLE}"
}

ROWS=$( rows "${TIER}" )

if [ -z "${ROWS}" ]; then
    echo "rediscovery: no rows for tier ${TIER} in ${TABLE}" >&2
    echo "rediscovery: FAIL (a battery with nothing in it proves nothing)"
    exit 2
fi

pass=0
fail=0

# run_row <patch> <stage> <test>
run_row()
{
    local _patch _stage _test _scratch _rc _out _assertions

    _patch=$1
    _stage=$2
    _test=$3

    echo "== ${_patch}: expecting ${_test} to fail"

    if [ ! -r "${HERE}/${_patch}" ]; then
        echo "   FAIL: no such patch: ${HERE}/${_patch}"
        fail=$(( fail + 1 ))
        return 0
    fi

    _scratch=$( mktemp -d "${TMPDIR:-/tmp}/seance-rediscover.XXXXXX" ) || return 1

    # A copy, not a checkout: this must work from a worktree, an export or an
    # installed module directory, none of which is guaranteed to be a git
    # repository. Written as two commands rather than one pipeline, so that
    # each half answers for itself -- a create that failed into an extract that
    # succeeded is the false pass this repository keeps finding.
    if ! ( cd "${ROOT}" && tar -cf "${_scratch}.tar" \
            --exclude ./.git --exclude ./out . ); then
        echo "   FAIL: could not archive the tree"
        rm -rf "${_scratch}" "${_scratch}.tar"
        fail=$(( fail + 1 ))
        return 0
    fi
    if ! ( cd "${_scratch}" && tar -xf "${_scratch}.tar" ); then
        echo "   FAIL: could not unpack the tree into ${_scratch}"
        rm -rf "${_scratch}" "${_scratch}.tar"
        fail=$(( fail + 1 ))
        return 0
    fi
    rm -f "${_scratch}.tar"

    if ! ( cd "${_scratch}" && patch -p1 -s < "${HERE}/${_patch}" ); then
        echo "   FAIL: the patch did not apply -- the protection it reverts has moved"
        rm -rf "${_scratch}"
        fail=$(( fail + 1 ))
        return 0
    fi

    if [ ! -r "${_scratch}/${_test}" ]; then
        echo "   FAIL: ${_test} is not in the copy"
        rm -rf "${_scratch}"
        fail=$(( fail + 1 ))
        return 0
    fi

    _out="${_scratch}/rediscovery.log"

    env SEANCE_ROOT="${_scratch}" SEANCE_STAGES="${_stage}" \
        sh "${_scratch}/${_test}" > "${_out}" 2>&1
    _rc=$?

    _assertions=$( awk '/^ok |^not ok / { n++ } END { print n + 0 }' "${_out}" )

    if [ "${_assertions}" -eq 0 ]; then
        echo "   FAIL: the patched run made no assertions at all (exit ${_rc});"
        echo "         a test that did not run is not a rediscovery"
        sed -e 's/^/         /' "${_out}" | tail -20
        rm -rf "${_scratch}"
        fail=$(( fail + 1 ))
        return 0
    fi

    if [ "${_rc}" -eq 0 ]; then
        echo "   FAIL: ${_test} still passed with the protection reverted"
        echo "         (${_assertions} assertions ran, none of them noticed)"
        rm -rf "${_scratch}"
        fail=$(( fail + 1 ))
        return 0
    fi

    echo "   PASS: rediscovered (exit ${_rc}, ${_assertions} assertions), by:"
    awk '/^not ok / { print "         " $0 }' "${_out}"

    rm -rf "${_scratch}"
    pass=$(( pass + 1 ))
    return 0
}

OIFS=$IFS
IFS="
"
for row in ${ROWS}; do
    IFS=$OIFS
    p=$( printf '%s' "${row}" | awk -F "${TAB}" '{ print $1 }' )
    s=$( printf '%s' "${row}" | awk -F "${TAB}" '{ print $3 }' )
    f=$( printf '%s' "${row}" | awk -F "${TAB}" '{ print $4 }' )
    run_row "${p}" "${s}" "${f}"
    IFS="
"
done
IFS=$OIFS

printf 'rediscovery tier %s: %d rediscovered, %d not\n' "${TIER}" "${pass}" "${fail}"

[ "${fail}" -eq 0 ] && exit 0
exit 1
