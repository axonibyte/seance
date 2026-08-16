#!/bin/sh
# Tier 1 -- the CBSD verb wrapper's argument passing.
#
# `seance` at the repository root is the only file that runs under cbsdsh, and
# all it does is copy CBSD's facts into the environment and exec the plain
# dispatcher (D-2). Everything about it that can be got wrong is in that one
# handover, and the way to get it wrong is silent: CBSD turns `key=value` words
# named in CIXARG/CIXOPTARG into shell variables and drops everything else into
# CIX_OTHER_ARGS (docs/cbsd-module-notes.md §2), so
#
#     cbsd seance config --check        ->  mode=''      CIX_OTHER_ARGS='config --check'
#     cbsd seance mode=config --check   ->  mode='config' CIX_OTHER_ARGS='--check'
#
# A wrapper that reads `mode` and ignores CIX_OTHER_ARGS answers the second
# form by running `config` WITHOUT `--check`: the operator asked for a
# validation and got a dump, exit 0, and no indication that the flag went
# nowhere. That is the defect this file exists to keep out, and it is a test
# rather than a comment because the wrapper is otherwise only exercised on a
# host with CBSD on it.
#
# cbsdsh is faked, not mocked away: the wrapper is run by /bin/sh with the two
# files it sources replaced by empty ones, `cixinit` defined as a shell function
# in the second of them (which is where a sourced definition would come from
# anyway), and `bin/seance` replaced by a script that prints what it was
# handed. Nothing about the handover under test is stubbed -- only the shell it
# would normally run under, which cannot be installed here (the cbsd binary is
# 0500 cbsd:cbsd).
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

DIR=$( t_tmpdir )
TREE="${DIR}/seance.d"
FAKE="${DIR}/cbsdsh"

mkdir -p "${TREE}/bin" "${FAKE}"

cp "${T_ROOT}/seance" "${TREE}/seance"

# The dispatcher, replaced by something that answers the only two questions
# this file asks: what argument vector arrived, and what environment came with
# it.
cat > "${TREE}/bin/seance" <<'EOF'
#!/bin/sh
printf 'argv:[%s]\n' "$*"
printf 'argc:[%d]\n' "$#"
env | grep '^SEANCE_CBSD_' | LC_ALL=C sort
EOF
chmod 0755 "${TREE}/bin/seance"

# The two files the wrapper sources, and the builtin it then calls. cixinit is
# a builtin of the cbsd binary, not a shell function (module notes §2), so a
# fake has to come from somewhere the wrapper already sources.
: > "${FAKE}/nc.subr"
cat > "${FAKE}/tools" <<'EOF'
cixinit() { :; }
EOF

# run <mode> <other-args>  -- the wrapper, as cbsdsh would have left it.
#
# The variable names are CBSD's, not seance's: workdir, nodename, jailsysdir,
# jaildatadir, dbdir, etcdir, CIX_DISTDIR, myversion, mode, CIX_OTHER_ARGS
# (cbsd.conf:21-99).
run()
{
    env -i PATH="${PATH}" \
        subrdir="${FAKE}" tools="${FAKE}/tools" REALPATH_CMD=/bin/realpath \
        workdir=/wd nodename=alpha.example.net \
        jailsysdir=/wd/jails-system jaildatadir=/wd/jails-data \
        dbdir=/wd/var/db etcdir=/wd/etc \
        CIX_DISTDIR=/usr/local/cbsd myversion=15.0.9 \
        mode="$1" CIX_OTHER_ARGS="$2" \
        /bin/sh "${TREE}/seance" > "${DIR}/out" 2> "${DIR}/err"
    RC=$?
    OUT=$( cat "${DIR}/out" )
    ERR=$( cat "${DIR}/err" )
}

t_plan 19

# --- the bare form ----------------------------------------------------------

run "" "config --check"
t_is "${RC}" "0" "the bare form runs the dispatcher"
t_like "${OUT}" '^argv:\[config --check\]$' \
    "a bare verb and its flag both arrive, from CIX_OTHER_ARGS"
t_like "${OUT}" '^argc:\[2\]$' \
    "as two arguments, not as one string the dispatcher would have to split"
t_is "${ERR}" "" "and nothing is said on stderr"

run "" "repl --guest web01 --now"
t_like "${OUT}" '^argv:\[repl --guest web01 --now\]$' \
    "a verb with several arguments arrives whole"
t_like "${OUT}" '^argc:\[4\]$' "as four arguments"

# --- the mode= form ---------------------------------------------------------
#
# The form the help text tells operators about, and the one that used to lose
# everything after the verb.

run "config" ""
t_like "${OUT}" '^argv:\[config\]$' "mode=<verb> alone runs that verb"

run "config" "--check"
t_like "${OUT}" '^argv:\[config --check\]$' \
    "mode=config --check reaches the dispatcher WITH its --check"
t_like "${OUT}" '^argc:\[2\]$' "as two arguments"

run "repl" "--guest web01 --now"
t_like "${OUT}" '^argv:\[repl --guest web01 --now\]$' \
    "and mode=repl carries the flags that follow it"
t_like "${OUT}" '^argc:\[4\]$' "as four arguments"

# --- nothing at all ---------------------------------------------------------

run "" ""
t_like "${OUT}" '^argc:\[0\]$' \
    "with neither a mode nor other args the dispatcher is run with none"

# --- the facts the wrapper exists to carry ----------------------------------

run "" "version"
t_like "${OUT}" '^SEANCE_CBSD_WORKDIR=/wd$' "workdir is exported"
t_like "${OUT}" '^SEANCE_CBSD_NODENAME=alpha\.example\.net$' "nodename is exported"
t_like "${OUT}" '^SEANCE_CBSD_DBDIR=/wd/var/db$' "dbdir is exported"
t_like "${OUT}" '^SEANCE_CBSD_DISTDIR=/usr/local/cbsd$' "the module dist dir is exported"
t_is "$( printf '%s\n' "${OUT}" | grep -c '^SEANCE_CBSD_' )" "8" \
    "eight CBSD facts are exported, and the dispatcher may rely on every one"

# --- $0 is a symlink, twice over --------------------------------------------
#
# ${workdir}/modules/seance is a symlink planted by initenv stage 8, so the
# wrapper must resolve its own path before looking for bin/ beside it. A
# wrapper that used ${0%/*} would look for the dispatcher in the symlink's
# directory and find nothing.

mkdir -p "${DIR}/modules"
ln -sf "${TREE}/seance" "${DIR}/modules/seance"

env -i PATH="${PATH}" \
    subrdir="${FAKE}" tools="${FAKE}/tools" REALPATH_CMD=/bin/realpath \
    workdir=/wd nodename=alpha.example.net \
    jailsysdir=/wd/jails-system jaildatadir=/wd/jails-data \
    dbdir=/wd/var/db etcdir=/wd/etc \
    CIX_DISTDIR=/usr/local/cbsd myversion=15.0.9 \
    mode="" CIX_OTHER_ARGS="version" \
    /bin/sh "${DIR}/modules/seance" > "${DIR}/out" 2> "${DIR}/err"
t_is "$?" "0" "reached through a symlink, the wrapper still finds its dispatcher"
t_like "$( cat "${DIR}/out" )" '^argv:\[version\]$' \
    "and hands it the same arguments"

t_done
