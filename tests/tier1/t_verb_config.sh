#!/bin/sh
# Tier 1 -- the 'seance config' verb: argument handling and exit discipline.
#
# In tier 1 because the dispatcher is pure /bin/sh with no ZFS, no jails and no
# CBSD: it reads a file and prints. The exit code is the whole contract here --
# 0 the config is valid, 1 it loaded and is invalid, 2 it could not be found or
# could not be parsed -- because that is what a cron line and a config
# management run will act on, and neither of them reads the text.
#
# The two ways to be wrong are asserted separately: a config that does not
# parse must never look like a config that merely has a problem, and neither
# must ever look like a pass.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SEANCE="${T_ROOT}/bin/seance"
SAMPLE="${T_ROOT}/etc/seance.conf.sample"
DIR=$( t_tmpdir )

cat > "${DIR}/bad-semantics.conf" <<'EOF'
cadence=30
node_alpha_nodename=alpha.example.net
node_alpha_mgmt=alpha-mgmt.example.net
node_bravo_nodename=bravo.example.net
node_bravo_mgmt=bravo-mgmt.example.net
EOF

printf 'cadance=900\n' > "${DIR}/bad-syntax.conf"

# run <args...>  -- run the verb with no config environment of its own,
# leaving stdout in ${OUT}, stderr in ${ERR} and the status in ${RC}.
run()
{
    env -u SEANCE_CONF -u SEANCE_CBSD_WORKDIR \
        sh "${SEANCE}" "$@" > "${DIR}/out" 2> "${DIR}/err"
    RC=$?
    OUT=$( cat "${DIR}/out" )
    ERR=$( cat "${DIR}/err" )
}

t_plan 29

# --- the happy path --------------------------------------------------------

run config --file "${SAMPLE}"
t_is "${RC}" "0" "config on a valid file exits 0"
t_like "${OUT}" '^fleet default cadence 900$' "the dump is on stdout"
t_like "${OUT}" '^node alpha heir bravo$' "and includes the nodes"
t_is "$( printf '%s\n' "${OUT}" | tail -n 1 )" "PASS" \
    "the verdict line is last"
t_is "${ERR}" "" "nothing goes to stderr on the happy path"

run config --file "${SAMPLE}" --check
t_is "${RC}" "0" "config --check on a valid file exits 0"
t_is "${OUT}" "PASS" "and prints only its verdict"

run config --check --file "${SAMPLE}"
t_is "${RC}" "0" "the flags may come in either order"
t_is "${OUT}" "PASS" "with the same result"

run config "--file=${SAMPLE}" --check
t_is "${RC}" "0" "--file=<path> works too"

# --- loaded, but invalid: exit 1 -------------------------------------------

run config --file "${DIR}/bad-semantics.conf"
t_is "${RC}" "1" "config on an invalid file exits 1"
t_like "${OUT}" '^FAIL: [0-9]+ problems ' "the verdict says how many"
t_like "${OUT}" 'seance config --check' \
    "and says where to get the list"
t_like "${OUT}" '^fleet set cadence 30$' \
    "the dump is still printed: an invalid config is still worth seeing"
t_unlike "${OUT}" '^problem: ' \
    "the problem list belongs to --check, not to the plain dump"

run config --file "${DIR}/bad-semantics.conf" --check
t_is "${RC}" "1" "config --check on an invalid file exits 1"
t_like "${OUT}" '^problem: cadence: 30 is outside 60\.\.86400$' \
    "--check prints the problem"
t_is "$( printf '%s\n' "${OUT}" | tail -n 1 )" "FAIL: 1 problems" \
    "and ends with the verdict"

# --- could not be parsed, or could not be found: exit 2 --------------------

run config --file "${DIR}/bad-syntax.conf"
t_is "${RC}" "2" "a file that does not parse exits 2, not 1"
t_like "${ERR}" ':1: unknown key "cadance"' \
    "the parse error names the file and line, on stderr"

run config --file "${DIR}/bad-syntax.conf" --check
t_is "${RC}" "2" "--check on a file that does not parse also exits 2"

run config --file "${DIR}/nosuch.conf"
t_is "${RC}" "2" "a missing file exits 2"

run config
t_is "${RC}" "2" "with no file and no environment, config exits 2"
t_like "${ERR}" 'no config file' "and says so"

run config --nope --file "${SAMPLE}"
t_is "${RC}" "2" "an unknown argument exits 2"

run config --file
t_is "${RC}" "2" "--file with no path exits 2"

# --- the environment ------------------------------------------------------

SEANCE_CONF="${SAMPLE}" sh "${SEANCE}" config --check > "${DIR}/out" 2>&1
t_is "$?:$( cat "${DIR}/out" )" "0:PASS" "SEANCE_CONF names the file"

env -u SEANCE_CONF SEANCE_CBSD_WORKDIR="${DIR}/wd" \
    sh "${SEANCE}" config --check > "${DIR}/out" 2> "${DIR}/err"
t_is "$?" "2" \
    "the workdir path is used when SEANCE_CONF is unset"
t_like "$( cat "${DIR}/err" )" "${DIR}/wd/etc/seance.conf: not readable" \
    "and it is \${workdir}/etc/seance.conf, per decision D-3"

t_done
