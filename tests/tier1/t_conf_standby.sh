#!/bin/sh
# Tier 1 -- repl_standby_root: the three-step precedence (D-67).
#
# A peer's standby root is, in order: its own node_<peer>_standby_root if it
# has one; otherwise the fleet standby_root with %n substituted for the peer's
# key (D-59); otherwise unset, which repl_standby_root reports as rc 1 so the
# caller derives a default. This file exercises repl_standby_root and
# repl_standby_root_derived directly -- no adapter, no ZFS, no CBSD -- because
# both are pure functions of the loaded configuration and their arguments.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/common.subr
. "${T_ROOT}/lib/common.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/conf.subr
. "${T_ROOT}/lib/conf.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/repl.subr
. "${T_ROOT}/lib/repl.subr"

DIR=$( t_tmpdir )

t_plan 17

# --- neither a node override nor a fleet setting: the caller derives -------

printf '' > "${DIR}/bare.conf"
conf_load "${DIR}/bare.conf" || t_diag "bare.conf failed to load"

t_rc 1 "nothing configured: repl_standby_root defers to the caller" -- \
    repl_standby_root alpha
t_stdout_is "" "and prints nothing" -- repl_standby_root alpha

t_stdout_is "mypool/standby" \
    "repl_standby_root_derived falls back to <root's parent>/standby" -- \
    repl_standby_root_derived mypool/alpha01

# A ROOT ALREADY INSIDE A STANDBY TREE IS REFUSED (D-188): a guest promoted in
# place lives under <standby_root>/<deadkey>/, and deriving from it answers a
# standby root nested inside the dead node's estate -- which is where a real
# fleet shipped a 3.82 GB copy of a promoted guest. A CBSD-layout shape, the
# pseudo-cluster's shape, and the textbook one that still derives:
t_rc 1 "a promoted-in-place root (CBSD-layout shape) is refused rather than derived from" -- \
    repl_standby_root_derived mypool/cbsd/jails-data/standby/alpha/web01-data
t_rc 1 "and the pseudo-cluster's shape too" -- \
    repl_standby_root_derived tank/state/seance/bravo/standby/alpha/web01
t_stdout_is "mypool/cbsd/jails-data/standby" \
    "while a home guest on the same fleet still derives the standby root" -- \
    repl_standby_root_derived mypool/cbsd/jails-data/web01-data

# --- the fleet setting, verbatim, when no peer owns an override ------------

cat > "${DIR}/fleet.conf" <<'EOF'
standby_root=mypool/standby
EOF
conf_load "${DIR}/fleet.conf" || t_diag "fleet.conf failed to load"

t_stdout_is "mypool/standby" \
    "a fleet standby_root with no %n is used verbatim" -- \
    repl_standby_root alpha
t_stdout_is "mypool/standby" \
    "...for any peer, since there is nothing to substitute" -- \
    repl_standby_root bravo

# --- %n substitution, D-59, unaffected by this change -----------------------

cat > "${DIR}/pct.conf" <<'EOF'
standby_root=tank/state/seance/%n/standby
EOF
conf_load "${DIR}/pct.conf" || t_diag "pct.conf failed to load"

t_stdout_is "tank/state/seance/alpha/standby" \
    "%n is replaced with the PEER's key" -- repl_standby_root alpha
t_stdout_is "tank/state/seance/bravo/standby" \
    "...and again for a different peer, same config" -- \
    repl_standby_root bravo

# --- a per-node override, D-67 --------------------------------------------

cat > "${DIR}/override.conf" <<'EOF'
node_alpha_standby_root=alphapool/own-standby
EOF
conf_load "${DIR}/override.conf" || t_diag "override.conf failed to load"

t_stdout_is "alphapool/own-standby" \
    "a node's own standby_root override is honoured" -- \
    repl_standby_root alpha
t_rc 1 "a peer with no override and no fleet setting still defers" -- \
    repl_standby_root bravo

# --- precedence: the override beats the fleet setting -----------------------
#
# This is the load-bearing assertion: mutation-checked by reversing the
# lookup order in lib/repl.subr and confirming this row fails (see report).

cat > "${DIR}/precedence.conf" <<'EOF'
standby_root=tank/state/seance/%n/standby
node_alpha_standby_root=alphapool/own-standby
EOF
conf_load "${DIR}/precedence.conf" || t_diag "precedence.conf failed to load"

t_stdout_is "alphapool/own-standby" \
    "alpha's own override beats the fleet setting, %n and all" -- \
    repl_standby_root alpha
t_stdout_is "tank/state/seance/bravo/standby" \
    "bravo has no override, so bravo still gets the fleet %n substitution" -- \
    repl_standby_root bravo

# --- an override does not leak to a peer that does not own it --------------

cat > "${DIR}/leak.conf" <<'EOF'
node_alpha_standby_root=alphapool/own-standby
EOF
conf_load "${DIR}/leak.conf" || t_diag "leak.conf failed to load"

t_stdout_is "" "alpha's override is not bravo's answer" -- \
    repl_standby_root bravo
t_rc 1 "...which is rc 1, not a borrowed value" -- repl_standby_root bravo

# --- the override is a config key like any other: config --check accepts it

cat > "${DIR}/check.conf" <<'EOF'
node_alpha_nodename=alpha.example.net
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_alpha_standby_root=alphapool/standby
node_bravo_nodename=bravo.example.net
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
EOF
t_rc 0 "config --check accepts node_<k>_standby_root" -- \
    sh "${T_ROOT}/bin/seance" config --file "${DIR}/check.conf" --check

t_done
