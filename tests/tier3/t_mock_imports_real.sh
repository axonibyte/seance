#!/bin/sh
# Tier 3 -- the mock imports the real parsers (TESTING.md §5).
#
# "The mock imports the real parsers (snapshot-name, config) rather than
# reimplementing them, so it cannot drift into testing itself." That sentence
# is only true while somebody checks it, because reimplementing a parser inside
# a mock is never a decision anyone announces -- it is one line, written in a
# hurry, that makes a failing tier-4 row go green.
#
# So, read as text and as behaviour:
#
#   1. tests/mock-adapter.subr sources lib/policy.subr and lib/conf.subr;
#   2. it defines no function named pol_* or conf_* -- no shadowing, no
#      "improved" copy, no local helper that happens to take the same name;
#   3. it actually CALLS both of them, which a source line alone does not
#      prove;
#   4. and, sourced for real, the pol_*/conf_* functions it exposes are the
#      ones the library defines -- checked by breaking a library function in a
#      copy of the tree and watching the mock's answer change with it. A mock
#      that had its own copy would go on answering correctly, which is the
#      failure this test exists to make visible.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

MOCK="${T_ROOT}/tests/mock-adapter.subr"

t_plan 8

# 1. the source lines
t_like "$( cat "${MOCK}" )" '^\. "\$\{MOCK_ROOT\}/lib/policy\.subr"$' \
    "the mock sources lib/policy.subr"
t_like "$( cat "${MOCK}" )" '^\. "\$\{MOCK_ROOT\}/lib/conf\.subr"$' \
    "the mock sources lib/conf.subr"

# 2. no shadowing definitions
shadows=$( sed -n -e 's/^\(\(pol\|conf\)_[a-z0-9_]*\)()[ \t]*$/\1/p' "${MOCK}" )
t_is "${shadows}" "" \
    "the mock defines no pol_* or conf_* function of its own"

# The private forms too: _pol_* and _conf_* are the same promise.
private=$( sed -n -e 's/^\(_\(pol\|conf\)_[a-z0-9_]*\)()[ \t]*$/\1/p' "${MOCK}" )
t_is "${private}" "" \
    "the mock defines no _pol_* or _conf_* function of its own"

# 3. it calls them
calls=$( grep -c -E '(^|[^A-Za-z0-9_])(pol|conf)_[a-z0-9_]+' "${MOCK}" )
t_isnt "${calls}" "0" "the mock calls the real parsers"

# 4. behaviour: the mock's snapshot names come from lib/policy.subr's formatter
SEANCE_MOCK_LINEAGE_NOW=1786000000
SEANCE_MOCK_LINEAGE_N=1
export SEANCE_MOCK_LINEAGE_NOW SEANCE_MOCK_LINEAGE_N

names=$( SEANCE_ROOT="${T_ROOT}" sh -c \
    '. "${SEANCE_ROOT}/tests/mock-adapter.subr"; mock_zfs_list pool0/web01' )
t_like "${names}" '^pool0/web01@seance-alpha-[0-9]{8}T[0-9]{6}Z$' \
    "the mock's fixture lineage is a name the wire protocol accepts"

# Break the formatter in a copy of the tree. If the mock imports it, the mock's
# output changes; if the mock has its own copy, it does not.
scratch=$( t_tmpdir )
mkdir -p "${scratch}/lib" "${scratch}/tests"
cp "${T_ROOT}/lib/conf.subr" "${scratch}/lib/"
cp "${T_ROOT}/tests/mock-adapter.subr" "${scratch}/tests/"
sed -e 's|^    printf .%s%s-%s\\n. "${POL_SNAP_PREFIX}" "${_node}" "${_ts}"$|    printf "MUTATED-%s-%s\\n" "${_node}" "${_ts}"|' \
    "${T_ROOT}/lib/policy.subr" > "${scratch}/lib/policy.subr"

t_isnt "$( grep -c MUTATED "${scratch}/lib/policy.subr" )" "0" \
    "the mutation reached the copy of lib/policy.subr"

mutated=$( SEANCE_ROOT="${scratch}" sh -c \
    '. "${SEANCE_ROOT}/tests/mock-adapter.subr"; mock_zfs_list pool0/web01' )
t_like "${mutated}" '^pool0/web01@MUTATED-alpha-' \
    "breaking lib/policy.subr's formatter breaks the mock's fixtures with it"

t_done
