#!/bin/sh
# seance test runner.
#
#   SEANCE_TIERS=1,2,3,4   which tiers to run (this is the default).
#
# Each tier is the directory tests/tier<N>/; every t_*.sh in it is one test
# file, run as its own process. Anything else in the directory (README, data,
# vectors) is ignored, so an empty tier is "no tests" and not a failure -- but
# a test file that exits non-zero is, whatever it printed.
#
# When $REAPER_OUT is set the full log of each tier is also written to
# $REAPER_OUT/tests-<tier>.log. By redirection, never by tee: a pipeline's exit
# status is the last command's, and 'suite | tee' reports tee's opinion of a
# failed suite as a pass.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

SEANCE_ROOT=$( cd "$( dirname "$( realpath "$0" )" )/.." && pwd )
export SEANCE_ROOT

SEANCE_TIERS=${SEANCE_TIERS:-1,2,3,4}
REAPER_OUT=${REAPER_OUT:-}
REAPER_STATE=${REAPER_STATE:-}

# run_tier <n>
#
# Runs every test file of one tier, printing TAP and a summary line. Returns 0
# only if every file exited 0 and no assertion was "not ok".
run_tier()
{
    local _tier _dir _f _rc _frc _ok _notok _counts _files _tmp

    _tier=$1
    _dir="${SEANCE_ROOT}/tests/tier${_tier}"
    _rc=0
    _ok=0
    _notok=0
    _files=0

    if [ ! -d "${_dir}" ]; then
        echo "tier ${_tier}: no such directory: ${_dir}" >&2
        return 1
    fi

    _tmp=$( mktemp -d "${TMPDIR:-/tmp}/seance-run.XXXXXX" ) || return 1

    for _f in "${_dir}"/t_*.sh; do
        [ -f "${_f}" ] || continue
        _files=$(( _files + 1 ))

        echo "# --- ${_f#"${SEANCE_ROOT}"/}"
        sh "${_f}" > "${_tmp}/out" 2>&1
        _frc=$?
        cat "${_tmp}/out"

        # Counted with awk rather than 'grep -c', which exits 1 when it counts
        # zero and would make an empty count look like a runner failure.
        _counts=$( awk '
            /^ok /     { o++ }
            /^not ok / { n++ }
            END        { printf "%d %d", o + 0, n + 0 }
        ' "${_tmp}/out" )
        _ok=$(( _ok + ${_counts% *} ))
        _notok=$(( _notok + ${_counts#* } ))

        if [ "${_frc}" -ne 0 ]; then
            echo "# FILE FAILED (exit ${_frc}): ${_f}"
            _rc=1
        fi
    done

    rm -rf "${_tmp}"

    if [ "${_files}" -eq 0 ]; then
        echo "tier ${_tier}: no tests"
        return 0
    fi

    [ "${_notok}" -gt 0 ] && _rc=1

    if [ "${_rc}" -eq 0 ]; then
        echo "tier ${_tier}: PASS $(( _ok ))/$(( _ok + _notok ))"
    else
        echo "tier ${_tier}: FAIL $(( _ok ))/$(( _ok + _notok ))"
    fi

    return "${_rc}"
}

## MAIN

overall=0

# In a reaper session the guest must be prepared before any tier runs, and a
# failure there is a failure of the suite, not a warning.
if [ -n "${REAPER_STATE}" ]; then
    echo "# guest prologue"
    sh "${SEANCE_ROOT}/tests/lib/guest-prologue.sh"
    prologue_rc=$?
    if [ "${prologue_rc}" -ne 0 ]; then
        echo "seance tests: FAIL (guest prologue exited ${prologue_rc})" >&2
        echo "seance tests: FAIL"
        exit 1
    fi
fi

OIFS=$IFS
IFS=,
for tier in ${SEANCE_TIERS}; do
    IFS=$OIFS

    case "${tier}" in
        ''|*[!0-9]*)
            echo "seance tests: FAIL (bad tier in SEANCE_TIERS: ${tier})" >&2
            exit 2
            ;;
    esac

    if [ -n "${REAPER_OUT}" ]; then
        run_tier "${tier}" > "${REAPER_OUT}/tests-${tier}.log" 2>&1
        rc=$?
        cat "${REAPER_OUT}/tests-${tier}.log"
    else
        run_tier "${tier}"
        rc=$?
    fi

    [ "${rc}" -ne 0 ] && overall=1

    IFS=,
done
IFS=$OIFS

if [ "${overall}" -eq 0 ]; then
    echo "seance tests: PASS"
else
    echo "seance tests: FAIL"
fi

exit "${overall}"
