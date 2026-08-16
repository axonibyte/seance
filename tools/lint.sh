#!/bin/sh
# seance lint: syntax, static analysis, and the cheap test tiers.
#
# This is also the reaper [build] command, so it must be honest about its own
# exit status: every phase's status is captured explicitly and nothing is piped
# into anything that could answer for it.
#
# Phases:
#   1. sh -n over every shell file in the tree
#   2. shellcheck -s sh -x over the same set, when shellcheck is installed
#      (it is on the workstation and absent in the guest -- said loudly, and
#      the phase is skipped rather than faked)
#   3. tests/run.sh with tiers 1-4
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

SEANCE_ROOT=$( cd "$( dirname "$( realpath "$0" )" )/.." && pwd )
export SEANCE_ROOT

rc=0

# Every shell file: anything named *.subr (sourced, so it has no shebang) plus
# anything whose first line is a shell interpreter -- /bin/sh for the project
# and /usr/local/bin/cbsd for the one file that runs under cbsdsh.
shell_files()
{
    local _f _line

    find "${SEANCE_ROOT}" -type f \
        ! -path "${SEANCE_ROOT}/.git/*" \
        ! -path "${SEANCE_ROOT}/out/*" \
        | sort | while read -r _f; do
        case "${_f}" in
            *.subr)
                printf '%s\n' "${_f}"
                continue
                ;;
        esac
        _line=""
        read -r _line < "${_f}" 2>/dev/null
        case "${_line}" in
            "#!/bin/sh"|"#!/bin/sh "*|"#!/usr/local/bin/cbsd")
                printf '%s\n' "${_f}"
                ;;
        esac
    done
}

files=$( shell_files )

if [ -z "${files}" ]; then
    echo "lint: FAIL: no shell files found under ${SEANCE_ROOT}" >&2
    exit 1
fi

echo "== lint phase 1: sh -n"
for f in ${files}; do
    if sh -n "${f}"; then
        echo "ok      ${f#"${SEANCE_ROOT}"/}"
    else
        echo "SYNTAX  ${f#"${SEANCE_ROOT}"/}" >&2
        rc=1
    fi
done

echo "== lint phase 2: shellcheck -s sh"
if command -v shellcheck >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    #   Deliberate word splitting: ${files} is a newline-separated list being
    #   turned into one argument per file.
    if shellcheck -s sh -x -- ${files}; then
        echo "shellcheck: clean"
    else
        echo "shellcheck: FAILED" >&2
        rc=1
    fi
else
    echo "shellcheck: absent, skipped -- install devel/shellcheck to run it" >&2
    echo "shellcheck: absent, skipped"
fi

echo "== lint phase 3: tiers 1-4"
SEANCE_TIERS=1,2,3,4 sh "${SEANCE_ROOT}/tests/run.sh"
tests_rc=$?
[ "${tests_rc}" -ne 0 ] && rc=1

if [ "${rc}" -eq 0 ]; then
    echo "seance lint: PASS"
else
    echo "seance lint: FAIL"
fi

exit "${rc}"
