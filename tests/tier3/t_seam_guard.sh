#!/bin/sh
# Tier 3 -- the seam guard (TESTING.md §4).
#
# Nothing outside lib/adapter.subr may invoke CBSD or the host's guest tooling.
# The adapter is the one file that knows CBSD exists; when CBSD changes an
# invocation convention, exactly one file changes. This guard is deliberately
# dumb -- it greps source as data -- because a clever guard is one that can be
# reasoned around.
#
# Forbidden tokens: cbsd, cbsdsql* (cbsdsqlro/cbsdsqlrw), jls, jexec, bhyvectl,
# and the string local.sqlite (CBSD's node database).
#
# Two allowances, both narrow, both stated here rather than in a code comment
# somewhere nobody reads:
#
#   1. Full-line comments -- a line whose first non-blank character is '#' --
#      are not scanned. A comment invokes nothing, and the alternative is a
#      module that may not mention in prose the system it is a module for. A
#      *trailing* comment on a line of code is still scanned, so the rule errs
#      towards failing. This allowance is also what lets the root verb wrapper
#      `seance` pass: its shebang (#!/usr/local/bin/cbsd) and the usage
#      examples in its ADDHELP text are written as comment lines. Its code
#      lines are scanned like every other file's, and contain none of the
#      tokens -- the wrapper's whole job (D-2) is to export environment and
#      exec bin/seance.
#   2. Any line containing the literal shebang '#!/usr/local/bin/cbsd'.
#      Recognising an interpreter is not invoking it, and tools/lint.sh has to
#      be able to classify the wrapper as a shell file.
#
# lib/adapter.subr is exempt entirely. It does not exist yet (M1); the guard
# runs over the tree and passes regardless, which is the point of writing it
# now rather than after there is something to hide behind it.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SCAN_DIRS="seance bin lib drivers rc.d devd cron tools"

PROG=$( t_tmpdir )/seam.awk
cat > "${PROG}" <<'AWK'
BEGIN {
    n = 0
    n++; pat[n] = "(^|[^A-Za-z0-9_])cbsd([^A-Za-z0-9_]|$)"; tok[n] = "cbsd"
    n++; pat[n] = "cbsdsql";                                 tok[n] = "cbsdsql"
    n++; pat[n] = "(^|[^A-Za-z0-9_])jls([^A-Za-z0-9_]|$)";   tok[n] = "jls"
    n++; pat[n] = "(^|[^A-Za-z0-9_])jexec([^A-Za-z0-9_]|$)"; tok[n] = "jexec"
    n++; pat[n] = "(^|[^A-Za-z0-9_])bhyvectl([^A-Za-z0-9_]|$)"; tok[n] = "bhyvectl"
    n++; pat[n] = "local\\.sqlite";                          tok[n] = "local.sqlite"
}

FILENAME == "lib/adapter.subr" { next }

# Allowance 1: full-line comments.
/^[ \t]*#/ { next }

# Allowance 2: the literal shebang of the cbsdsh wrapper.
/#!\/usr\/local\/bin\/cbsd/ { next }

{
    for (i = 1; i <= n; i++) {
        if ($0 ~ pat[i]) {
            printf "%s:%d: %s: %s\n", FILENAME, FNR, tok[i], $0
        }
    }
}
AWK

# guard_files <root>  -- the scanned files, relative to <root>, one per line.
guard_files()
{
    local _root _d _targets

    _root=$1
    _targets=""

    for _d in ${SCAN_DIRS}; do
        [ -e "${_root}/${_d}" ] && _targets="${_targets} ${_d}"
    done

    [ -n "${_targets}" ] || return 1

    # shellcheck disable=SC2086
    #   Deliberate word splitting: ${_targets} is a list of paths for find.
    ( cd "${_root}" && find ${_targets} -type f | sort )
}

# guard <root>  -- print one line per violation.
guard()
{
    local _root _files

    _root=$1
    _files=$( guard_files "${_root}" ) || return 1

    # shellcheck disable=SC2086
    #   Deliberate word splitting: one awk argument per file.
    ( cd "${_root}" && awk -f "${PROG}" ${_files} )
}

t_plan 6

# The guard must be scanning something. A guard over an empty file list passes
# forever and means nothing.
scanned=$( guard_files "${T_ROOT}" | wc -l | tr -d ' ' )
t_isnt "${scanned}" "0" "the seam guard scans a non-empty file list"

violations=$( guard "${T_ROOT}" )
t_is "${violations}" "" "no CBSD or guest tooling is invoked outside the adapter"

# Mutation check, permanent: plant an invocation in a scratch copy of the tree
# and require the guard to see it. A guard never observed failing has
# unmeasured value.
scratch=$( t_tmpdir )
for d in ${SCAN_DIRS}; do
    [ -e "${T_ROOT}/${d}" ] && cp -R "${T_ROOT}/${d}" "${scratch}/"
done
printf 'cbsd jls header=0 display=jname\n' >> "${scratch}/lib/common.subr"

planted=$( guard "${scratch}" )
t_like "${planted}" '^lib/common\.subr:[0-9]+: cbsd: ' \
    "a planted cbsd invocation is caught"

# The exemption is a file exemption, not a token exemption: the same line in
# lib/adapter.subr is allowed, and only there.
probe()
{
    local _dir

    _dir=$( t_tmpdir )
    mkdir -p "${_dir}/lib"
    printf '%s\n' "$2" > "${_dir}/lib/$1"
    guard "${_dir}"
}

t_is "$( probe adapter.subr 'cbsd jls header=0' )" "" \
    "lib/adapter.subr may invoke cbsd"
# shellcheck disable=SC2016
#   The single quotes are the point: these strings are source code being fed to
#   the guard, not shell to expand.
t_like "$( probe repl.subr 'jexec ${_jname} /bin/sh -c true' )" \
    '^lib/repl\.subr:1: jexec: ' \
    "a planted jexec outside the adapter is caught"
# shellcheck disable=SC2016
#   As above: source text, not an expansion.
t_like "$( probe repl.subr '_db=${dbdir}/local.sqlite' )" \
    '^lib/repl\.subr:1: local\.sqlite: ' \
    "a planted read of CBSD's database is caught"

t_done
