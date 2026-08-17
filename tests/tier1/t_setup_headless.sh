#!/bin/sh
# Tier 1 -- the `seance setup` verb: the headless path.
#
# lib/setup.subr's interactive wizard and its --non-interactive twin feed the
# SAME renderer (setup_render_canonical), which is what makes "every screen
# has a non-interactive equivalent" a checkable claim rather than a promise:
# this file never drives bsddialog (it needs a real terminal; handoff's own
# words are "No" to a script(1) harness for it) and instead exercises exactly
# the half that is workstation-testable -- --set, --answers and --from.
#
# tests/tier3/t_setup_bsddialog_coverage.sh is the other half: it asserts,
# from source, that every question the wizard could ask has an answer key this
# file could equally well drive by hand.
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
VEC="${T_ROOT}/tests/vectors/setup"
DIR=$( t_tmpdir )

# run <args...>  -- run setup with no config environment of its own, leaving
# stdout in ${OUT}, stderr in ${ERR} and the status in ${RC}.
run()
{
    env -u SEANCE_CONF -u SEANCE_CBSD_WORKDIR \
        sh "${SEANCE}" setup "$@" > "${DIR}/out" 2> "${DIR}/err"
    RC=$?
    OUT=$( cat "${DIR}/out" )
    ERR=$( cat "${DIR}/err" )
}

# strip_active <file>  -- every key=value line of a config file, comments and
# blank lines gone, leading whitespace trimmed. This is the "modulo comments"
# in the round-trip claim, defined once, here, as text -- not as a re-sort:
# order is asserted too, because setup's canonical field order and the
# sample's own hand-written order have to agree for the claim to mean
# anything.
strip_active()
{
    awk '
        {
            line = $0
            sub(/^[ \t]+/, "", line)
        }
        line == ""    { next }
        line ~ /^#/   { next }
        { print line }
    ' "$1"
}

t_plan 37

# --- headless generation from an answers file equals a committed conf ------

run --non-interactive --answers "${VEC}/basic.answers" --out "${DIR}/basic.conf"
t_is "${RC}" "0" "headless generation from an answers file exits 0"
t_like "${OUT}" "setup: wrote ${DIR}/basic.conf \\(PASS\\)" \
    "and says it wrote a passing configuration"
t_is "$( cat "${DIR}/basic.conf" )" "$( cat "${VEC}/basic.expected" )" \
    "and the file equals the committed expected conf, byte for byte"

# --- invalid answers are refused, with the conf_check problems -------------

run --non-interactive --answers "${VEC}/invalid.answers" --out "${DIR}/invalid.conf"
t_is "${RC}" "1" "invalid answers are refused: exit 1, not 0 or 2"
t_like "${OUT}" 'problem: cadence: 10 is outside 60\.\.86400' \
    "the range problem conf_check would report is shown"
t_like "${OUT}" 'problem: only one node is configured' \
    "so is the node-count problem"
t_like "${OUT}" 'setup: refusing to write an invalid configuration' \
    "and setup says it refused"
t_rc 1 "and nothing was written" -- test -e "${DIR}/invalid.conf"

run --non-interactive --answers "${VEC}/invalid.answers" \
    --out "${DIR}/invalid-allowed.conf" --allow-invalid
t_is "${RC}" "0" "--allow-invalid writes it anyway: exit 0"
t_like "${OUT}" 'written because --allow-invalid' \
    "and says so in the verdict line"
t_is "$( cat "${DIR}/invalid-allowed.conf" )" \
"cadence=10
node_alpha_nodename=alpha.example.net
node_alpha_mgmt=alpha-mgmt.example.net" \
    "and the (invalid) file is exactly the canonical render of the answers"

# --- --from round-trips the sample, modulo comments -------------------------

run --non-interactive --from "${SAMPLE}" --out "${DIR}/roundtrip.conf"
t_is "${RC}" "0" "--from the sample, with no further answers, exits 0"
t_is "$( cat "${DIR}/roundtrip.conf" )" "$( strip_active "${SAMPLE}" )" \
    "and reproduces exactly the sample's active lines, in the same order"

# --- --set overrides a seeded value, and adds a new one ---------------------

run --non-interactive --answers "${VEC}/basic.answers" \
    --set cadence=1234 --set witness=example-witness \
    --out "${DIR}/overridden.conf"
t_is "${RC}" "0" "--set on top of --answers still exits 0"
t_like "${OUT}" "wrote ${DIR}/overridden.conf \\(PASS\\)" "and still passes"
t_like "$( cat "${DIR}/overridden.conf" )" '^cadence=1234$' \
    "--set overrides a value the answers file provided"
t_like "$( cat "${DIR}/overridden.conf" )" '^witness=example-witness$' \
    "and --set can add a key the answers file never mentioned"
t_like "$( cat "${DIR}/overridden.conf" )" '^node_alpha_mgmt=alpha-mgmt\.example\.net$' \
    "and everything --set did not touch survives unchanged"

# --- --dump-answers / --answers is a lossless round trip --------------------

run --non-interactive --answers "${VEC}/basic.answers" \
    --dump-answers "${DIR}/dumped.answers" --out "${DIR}/first.conf"
t_is "${RC}" "0" "a run with --dump-answers still exits 0"
t_rc 0 "and it wrote an answers file" -- test -s "${DIR}/dumped.answers"

run --non-interactive --answers "${DIR}/dumped.answers" --out "${DIR}/replayed.conf"
t_is "${RC}" "0" "replaying the dumped answers exits 0"
t_is "$( cat "${DIR}/replayed.conf" )" "$( cat "${DIR}/first.conf" )" \
    "and produces byte-identical output to the run that dumped them"

# --- overwriting an existing file backs it up and prints the undo ----------

FIRST=$( cat "${DIR}/basic.conf" )
run --non-interactive --answers "${VEC}/invalid.answers" --allow-invalid \
    --out "${DIR}/basic.conf"
t_is "${RC}" "0" "overwriting an existing target still exits 0"
t_like "${OUT}" "undo: mv \"${DIR}/basic\\.conf\\.bak-[^\"]+\" \"${DIR}/basic\\.conf\"" \
    "and prints the undo, naming a timestamped backup"
BACKUP=$( find "${DIR}" -maxdepth 1 -name 'basic.conf.bak-*' | head -n 1 )
t_isnt "${BACKUP}" "" "and the backup file actually exists"
t_is "$( cat "${BACKUP}" )" "${FIRST}" \
    "and the backup holds exactly what was there before"

# A target that does not exist yet gets no backup, and says so.
run --non-interactive --answers "${VEC}/basic.answers" --out "${DIR}/fresh.conf"
t_like "${OUT}" "undo: rm \"${DIR}/fresh\\.conf\"" \
    "a fresh target's undo is 'rm', not a backup restore"

# --- usage errors: exit 2, nothing written ----------------------------------

run --non-interactive --set notakeyvalue --out "${DIR}/nope.conf"
t_is "${RC}" "2" "a --set with no '=' is a usage error"

run --non-interactive --set 'Bad Key=1' --out "${DIR}/nope.conf"
t_is "${RC}" "2" "a --set whose key is not [a-z0-9_]+ is a usage error"

run --non-interactive --set
t_is "${RC}" "2" "--set with nothing after it is a usage error"

run --non-interactive --out
t_is "${RC}" "2" "--out with nothing after it is a usage error"

run --nope --non-interactive
t_is "${RC}" "2" "an unknown flag is a usage error"

t_rc 1 "and none of the usage errors left a file behind" -- \
    test -e "${DIR}/nope.conf"

# --- target resolution: --out, then SEANCE_CONF, then nothing --------------

run --non-interactive --answers "${VEC}/basic.answers"
t_is "${RC}" "2" "with no --out and no environment, setup exits 2"
t_like "${ERR}" 'no target' "and says so, on stderr"

env -u SEANCE_CBSD_WORKDIR SEANCE_CONF="${DIR}/via-env.conf" \
    sh "${SEANCE}" setup --non-interactive --answers "${VEC}/basic.answers" \
    > "${DIR}/out" 2> "${DIR}/err"
t_is "$?" "0" "SEANCE_CONF names the target when --out is not given"
t_is "$( cat "${DIR}/via-env.conf" )" "$( cat "${VEC}/basic.expected" )" \
    "and it is the same canonical render either way"

t_done
