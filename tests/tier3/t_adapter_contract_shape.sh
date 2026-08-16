#!/bin/sh
# Tier 3 -- one adapter contract, three implementations (TESTING.md §4, §6).
#
# The adapter seam is only worth what its implementations have in common. This
# guard reads all of them AS TEXT and asserts, without running anything:
#
#   1. every adapter_* function defined in lib/adapter.subr is defined in
#      tests/mock-adapter.subr, and vice versa -- a mock missing a function is
#      a tier-4 suite that silently stops covering a rung; a mock with an extra
#      one is a test for something that does not exist;
#   2. the same for tests/cluster/adapter-pseudo.subr WHEN IT EXISTS. It does
#      not yet (it is U4's). Its absence is announced loudly on every run
#      rather than passed over, because a check that quietly covers two of
#      three implementations is how the third one drifts;
#   3. every adapter_* function carries exactly one '# contract:' line in the
#      comment block immediately above it -- the field order and the exit-code
#      promise, written where the function is;
#   4. those contract lines are BYTE-IDENTICAL between implementations. Two
#      adapters that describe their output differently do not have one
#      contract, whatever the conformance suite finds them agreeing on today;
#   5. every contract line ends in one of the three markers that say what empty
#      stdout means: [promises output], [list: may be empty], [no output].
#      This is the crashed-verifier lesson made mechanical -- a function whose
#      documentation does not say whether silence is an answer cannot be
#      checked for answering with silence.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

REAL="${T_ROOT}/lib/adapter.subr"
MOCK="${T_ROOT}/tests/mock-adapter.subr"
PSEUDO="${T_ROOT}/tests/cluster/adapter-pseudo.subr"

# functions <file>  -- the adapter_* functions the file defines, sorted.
functions()
{
    sed -n -e 's/^\(adapter_[a-z0-9_]*\)()[ \t]*$/\1/p' "$1" | LC_ALL=C sort
}

# contracts <file>
#
# "<function><TAB><contract line>" for every adapter_* definition, sorted by
# function. A function whose preceding comment block holds no '# contract:'
# line, or more than one, is reported as such rather than skipped: the missing
# contract IS the finding.
contracts()
{
    awk '
        /^#/ {
            if (started == 0) { started = 1; n = 0; c = "" }
            if ($0 ~ /^# contract:/) { n++; c = $0 }
            next
        }
        /^adapter_[a-z0-9_]*\(\)[ \t]*$/ {
            fn = $0
            sub(/\(\)[ \t]*$/, "", fn)
            if (started == 0)   { printf "%s\tNO-COMMENT-BLOCK\n", fn }
            else if (n == 0)    { printf "%s\tNO-CONTRACT-LINE\n", fn }
            else if (n > 1)     { printf "%s\t%d-CONTRACT-LINES\n", fn, n }
            else                { printf "%s\t%s\n", fn, c }
            started = 0
            next
        }
        { started = 0 }
    ' "$1" | LC_ALL=C sort
}

# unmarked <file>  -- contract lines that do not end in a promise marker.
#
# awk rather than 'grep -v', which exits 1 when it selects nothing -- and
# selecting nothing is exactly the passing case here.
unmarked()
{
    contracts "$1" | awk '
        /\[promises output\]$/     { next }
        /\[list: may be empty\]$/  { next }
        /\[no output\]$/           { next }
        { print }
    '
}

t_plan 11

real_fns=$( functions "${REAL}" )
t_isnt "${real_fns}" "" "lib/adapter.subr defines adapter_* functions"

mock_fns=$( functions "${MOCK}" )
t_is "${mock_fns}" "${real_fns}" \
    "tests/mock-adapter.subr defines exactly the real adapter's function set"

real_contracts=$( contracts "${REAL}" )
mock_contracts=$( contracts "${MOCK}" )

t_unlike "${real_contracts}" 'NO-CONTRACT-LINE|NO-COMMENT-BLOCK|-CONTRACT-LINES' \
    "every function in lib/adapter.subr carries exactly one '# contract:' line"
t_unlike "${mock_contracts}" 'NO-CONTRACT-LINE|NO-COMMENT-BLOCK|-CONTRACT-LINES' \
    "every function in tests/mock-adapter.subr carries exactly one '# contract:' line"

t_is "${mock_contracts}" "${real_contracts}" \
    "the mock's contract lines are identical to the real adapter's"

t_is "$( unmarked "${REAL}" )" "" \
    "every contract line says what empty stdout means"

# The pseudo-cluster adapter is U4's and does not exist yet. Its absence is a
# diagnostic, never a silent pass.
if [ -r "${PSEUDO}" ]; then
    pseudo_fns=$( functions "${PSEUDO}" )
    t_is "${pseudo_fns}" "${real_fns}" \
        "tests/cluster/adapter-pseudo.subr defines the same function set"
    t_is "$( contracts "${PSEUDO}" )" "${real_contracts}" \
        "the pseudo-cluster adapter's contract lines are identical"
else
    t_diag "tests/cluster/adapter-pseudo.subr does not exist yet (U4 builds it)"
    t_diag "TWO OF THE THREE ADAPTERS ARE CHECKED HERE, NOT THREE."
    t_ok "the pseudo-cluster adapter is absent, and said so"
    t_ok "the pseudo-cluster adapter is absent, and said so (contracts)"
fi

# Mutation checks, permanent, one mutation per copy so that each assertion is
# answering for its own defect and not for the other one's.
scratch=$( t_tmpdir )

sed -e '/^adapter_guest_sysdir()$/,/^}$/d' "${MOCK}" > "${scratch}/gone.subr"
t_isnt "$( functions "${scratch}/gone.subr" )" "${real_fns}" \
    "a mock missing one function is caught"

sed -e 's/^# contract: adapter_guest_held(name) -> 1|0 \[promises output\]$/# contract: adapter_guest_held(name) -> yes|no [promises output]/' \
    "${MOCK}" > "${scratch}/reworded.subr"
t_is "$( functions "${scratch}/reworded.subr" )" "${real_fns}" \
    "the reworded copy still has every function (so the next check is about the wording)"
t_isnt "$( contracts "${scratch}/reworded.subr" )" "${real_contracts}" \
    "a mock whose contract line was reworded is caught"

t_done
