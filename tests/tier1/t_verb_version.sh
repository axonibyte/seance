#!/bin/sh
# Tier 1 -- 'seance version', and the VERSION file it reads.
#
# The version is not decoration: it is what an operator quotes in a bug report
# and what a configuration-management run compares against a package. So it is
# read from one file, printed verbatim, and refused rather than guessed when
# that file cannot be read (README, "seance version").
#
# This verb is deliberately data-only -- "seance <version>" and nothing else,
# no verdict line -- so that `v=$( seance version )` is usable. That is stated
# in README's exit-codes section and asserted here, because a verdict line
# added later would silently break every caller that substitutes it.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SEANCE="${T_ROOT}/bin/seance"
DIR=$( t_tmpdir )

# run <args...> -- run the dispatcher with no seance environment of its own.
run()
{
    env -u SEANCE_CONF -u SEANCE_CBSD_WORKDIR \
        sh "${SEANCE}" "$@" > "${DIR}/out" 2> "${DIR}/err"
    RC=$?
    OUT=$( cat "${DIR}/out" )
    ERR=$( cat "${DIR}/err" )
}

t_plan 14

# --- the VERSION file ------------------------------------------------------

t_rc 0 "the module carries a VERSION file" -- test -r "${T_ROOT}/VERSION"

VER=$( cat "${T_ROOT}/VERSION" )
t_like "${VER}" '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$' \
    "VERSION holds one release number and nothing else"
t_is "$( wc -l < "${T_ROOT}/VERSION" | tr -d ' ' )" "1" \
    "VERSION is exactly one line: the verb reads the first and only the first"

# CBSD's own module verbs carry their version on line 2 as '#v<version>'
# (modules/pkg.d/pkg:2, modules/zfsinstall.d/zfsinstall:2) and seance's wrapper
# follows the convention. Two version numbers in one module is one too many:
# the one an operator reads out of `cbsd seance version` and the one the
# framework reads off the verb must be the same string, and nothing but a test
# keeps them so -- the wrapper is edited on a different day from VERSION.
t_is "$( sed -n '2s/^#v//p' "${T_ROOT}/seance" )" "${VER}" \
    "the CBSD verb's own '#v' marker is the version VERSION states"

# --- the verb ---------------------------------------------------------------

run version
t_is "${RC}" "0" "seance version exits 0"
t_is "${OUT}" "seance ${VER}" "and prints 'seance <the VERSION file>'"
t_is "${ERR}" "" "with nothing on stderr"
t_is "$( printf '%s\n' "${OUT}" | wc -l | tr -d ' ' )" "1" \
    "one line: this verb is data, not a report with a verdict line"

# --- arguments --------------------------------------------------------------
#
# A verb that quietly ignores an argument it does not implement is a verb
# somebody will one day pass --tsv to and then parse the answer as TSV.

run version --tsv
t_is "${RC}" "2" "an argument seance version does not implement is a usage error"
t_is "${OUT}" "" "and it prints no version at all when it refuses"

# --- when the file cannot be read ------------------------------------------
#
# Driven against a copy of the tree, because the verb resolves VERSION beside
# its own bin/ and there is no environment override for it -- by design: a
# version that can be pointed elsewhere is a version nobody can trust.

COPY="${DIR}/tree"
mkdir -p "${COPY}/bin" "${COPY}/lib"
cp "${T_ROOT}/bin/seance" "${COPY}/bin/seance"
cp "${T_ROOT}"/lib/*.subr "${COPY}/lib/"

: > "${COPY}/VERSION"
env -u SEANCE_CONF -u SEANCE_CBSD_WORKDIR \
    sh "${COPY}/bin/seance" version > "${DIR}/out" 2> "${DIR}/err"
t_is "$?" "1" "an empty VERSION file is an operation failure, not a blank version"
t_is "$( cat "${DIR}/out" )" "" "and nothing is printed as the version"

rm -f "${COPY}/VERSION"
env -u SEANCE_CONF -u SEANCE_CBSD_WORKDIR \
    sh "${COPY}/bin/seance" version > "${DIR}/out" 2> "${DIR}/err"
t_is "$?" "1" "a missing VERSION file is an operation failure"
t_like "$( cat "${DIR}/err" )" 'no readable VERSION file' \
    "and the diagnostic names what is missing"

t_done
