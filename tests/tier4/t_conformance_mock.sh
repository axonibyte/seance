#!/bin/sh
# Tier 4 -- the conformance suite against the mock adapter (TESTING.md §5, §6).
#
# The same tests/conformance/vectors.tsv that tier 5 will run against the real
# CBSD adapter and tier 6 against the pseudo-cluster one. Running it here, at
# workstation speed, is what makes the mock a stand-in for an adapter rather
# than a bag of functions that happen to be called from tests.
#
# Hooks for the other two tiers are left, deliberately unwired: this file
# chooses its adapter through SEANCE_ADAPTER, exactly as the dispatcher does,
# so tier 5's file will differ from it only in which adapter it names and which
# world it declares.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SEANCE_ADAPTER=${SEANCE_ADAPTER:-tests/mock-adapter.subr}
VECTORS="${T_ROOT}/tests/conformance/vectors.tsv"

# The mock answers from its fixtures when no script is set, which is what the
# vectors are written against. An inherited script would silently change what
# conformance means.
unset SEANCE_MOCK_SCRIPT
unset SEANCE_MOCK_LOG

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../mock-adapter.subr
. "${T_ROOT}/${SEANCE_ADAPTER}"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../conformance/run.subr
. "${T_ROOT}/tests/conformance/run.subr"

count=$( conformance_count "${VECTORS}" )

# A vector file that shrank to nothing would otherwise pass in silence.
if [ "${count}" -lt 3 ]; then
    t_plan 1
    t_not_ok "tests/conformance/vectors.tsv holds vectors"
    t_diag "conformance_count said ${count}"
    t_done
fi

t_plan "${count}"
conformance_run "${VECTORS}"
t_done
