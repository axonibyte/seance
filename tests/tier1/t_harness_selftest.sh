#!/bin/sh
# Tier 1 -- the harness's own oracle self-test.
#
# A harness that has never been observed failing is indistinguishable from a
# harness that cannot fail, and every other test in this repository is only
# worth what this file proves. So: run the harness inside itself, on cases
# built to fail, and assert that it says so and exits non-zero.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

export SEANCE_ROOT="${T_ROOT}"

# inner <body>
#
# Write a test file that sources the harness, run it in its own shell, and
# leave its output in ${INNER_OUT} and its status in ${INNER_RC}.
inner()
{
    local _dir

    _dir=$( t_tmpdir )

    {
        echo "#!/bin/sh"
        echo "set -u"
        echo ". \"${T_ROOT}/tests/lib/harness.subr\""
        printf '%s\n' "$1"
    } > "${_dir}/inner.sh"

    INNER_OUT=$( sh "${_dir}/inner.sh" 2>&1 )
    INNER_RC=$?
}

t_plan 17

# The positive control: the harness must be able to pass, or the failures
# below would prove nothing.
inner 't_plan 1
t_is a a "equal strings"
t_done'
t_is "${INNER_RC}" "0" "a passing t_is exits 0"
t_like "${INNER_OUT}" '^ok 1 - equal strings$' "a passing t_is prints ok"
t_like "${INNER_OUT}" '^# result 1 0 1$' "a passing run summarises 1 0 1"

# The point of the file: an assertion that fails must say 'not ok' and must
# make the file fail.
inner 't_plan 1
t_is one two "deliberate failure"
t_done'
t_isnt "${INNER_RC}" "0" "a failing t_is exits non-zero"
t_like "${INNER_OUT}" '^not ok 1 - deliberate failure$' \
    "a failing t_is prints not ok"
t_like "${INNER_OUT}" '^# got:  \[one\]$' "a failing t_is diagnoses got"
t_like "${INNER_OUT}" '^# result 0 1 1$' "a failing run summarises 0 1 1"

# A plan that does not match is a failure even when every assertion passed:
# a test file that dies half way through must not look green.
inner 't_plan 3
t_ok "only one"
t_done'
t_isnt "${INNER_RC}" "0" "a short plan exits non-zero"
t_like "${INNER_OUT}" 'plan mismatch: planned 3, ran 1' \
    "a short plan is diagnosed"

# A file that asserts nothing at all is a failure, not a pass.
inner 't_done'
t_isnt "${INNER_RC}" "0" "an empty test file exits non-zero"
t_like "${INNER_OUT}" 'no assertions ran' "an empty test file is diagnosed"

# t_rc must fail when the exit status is not the expected one.
inner 't_plan 1
t_rc 0 "false is not 0" -- false
t_done'
t_isnt "${INNER_RC}" "0" "t_rc fails on the wrong exit status"

# t_stdout_is compares stdout exactly, and must fail when it differs. Both
# directions, because an assertion that cannot fail is not an assertion.
inner 't_plan 2
t_stdout_is "hello" "echoes hello" -- echo hello
t_stdout_is "hello" "does not echo goodbye" -- echo goodbye
t_done'
t_isnt "${INNER_RC}" "0" "t_stdout_is fails on differing stdout"
t_like "${INNER_OUT}" '^ok 1 - echoes hello$' "t_stdout_is passes on equal stdout"
t_like "${INNER_OUT}" '^not ok 2 - does not echo goodbye$' \
    "t_stdout_is reports the mismatch"

# t_unlike is t_like inverted, and gets the same treatment.
inner 't_plan 2
t_unlike "seance 1.2.3" "^# " "a version line is not a comment"
t_unlike "seance 1.2.3" "seance" "this one must fail"
t_done'
t_like "${INNER_OUT}" '^ok 1 - a version line is not a comment$' \
    "t_unlike passes when the pattern is absent"
t_like "${INNER_OUT}" '^not ok 2 - this one must fail$' \
    "t_unlike fails when the pattern is present"

t_done
