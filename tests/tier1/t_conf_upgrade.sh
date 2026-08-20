#!/bin/sh
# Tier 1 -- the upgrade path: what a node that was running the PREVIOUS release
# still has on disk, and whether this one will read it.
#
# WHY THIS FILE EXISTS. `docs/INSTALL.md` §2 makes an upgrade a `git pull` and
# an `initenv` re-run, and nothing in this repository ever checked that the
# configuration and the state a previous release left behind survive it. They
# are not the same kind of promise:
#
#   * the FILE FORMATS are seance's own and it may not break them silently: a
#     lag record, a placement record and a succession record written by the
#     older release are what the newer one finds on the disk it boots onto;
#   * the VALIDATOR, by contrast, is allowed to grow rules -- but every rule it
#     grows turns some configuration that used to be valid into one that is
#     not, and `seance_load_conf` runs `conf_check` before EVERY verb
#     (bin/seance), so such a node stops running `repl`, `status`, `verify`,
#     `gate` and `promote` the moment the checkout moves. That is not a bug; it
#     is a MIGRATION, and the only wrong thing to do with it is not say so.
#
# WHAT THIS FOUND, at M5, driving the current tree against a v0.2.0 checkout:
# exactly one such rule has been added since that tag -- D-156's "a node armed
# to succeed a peer needs an interface to hear it on". A fleet whose bravo
# carries `node_bravo_auto_promote=alpha` and no `carp_interface` of any kind
# validated at v0.2.0 and is refused here. The rule is right (the automation
# was deaf and nothing said so); what was missing is that an operator upgrading
# would have met it on a running fleet rather than in the upgrade document.
#
# THE FIXTURES are the previous release's own files, committed verbatim:
#
#   tests/vectors/upgrade/seance.conf.sample-v0.2.0
#       the sample that release shipped -- the configuration a site is most
#       likely to have started from.
#   tests/vectors/upgrade/armed-without-carp-interface-v0.2.0.conf
#       the one shape that changed verdict, kept so that the change stays
#       deliberate: a future rule that refuses the SAMPLE would fail row 1
#       here, and a rule that stopped refusing this file would fail its row.
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
# shellcheck source=../../lib/policy.subr
. "${T_ROOT}/lib/policy.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/conf.subr
. "${T_ROOT}/lib/conf.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/repl.subr
. "${T_ROOT}/lib/repl.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/gate.subr
. "${T_ROOT}/lib/gate.subr"

SEANCE="${T_ROOT}/bin/seance"
FIX="${T_ROOT}/tests/vectors/upgrade"
OLD_SAMPLE="${FIX}/seance.conf.sample-v0.2.0"
OLD_ARMED="${FIX}/armed-without-carp-interface-v0.2.0.conf"

DIR=$( t_tmpdir )

t_plan 19

# ---------------------------------------------------------------------------
# 1. The previous release's own sample still loads and still validates
# ---------------------------------------------------------------------------

t_rc 0 "the previous release's sample is committed as a fixture" -- \
    test -r "${OLD_SAMPLE}"

t_rc 0 "it still parses" -- \
    sh "${SEANCE}" config --file "${OLD_SAMPLE}" --check
t_stdout_is "PASS" "and it still validates: an upgrade does not invalidate the file a site started from" -- \
    sh "${SEANCE}" config --file "${OLD_SAMPLE}" --check

# ---------------------------------------------------------------------------
# 2. No key the previous release documented has been removed
# ---------------------------------------------------------------------------
#
# A removed key is the harshest kind of migration: conf_load refuses an unknown
# key and returns 2 having loaded nothing (D-34), so the node stops dead. If one
# ever has to go, this row is where the decision gets made rather than
# discovered.

old_keys()
{
    awk '
        {
            line = $0
            sub(/^[ \t]+/, "", line)
            sub(/^#+[ \t]*/, "", line)
            if (line ~ /^[a-z0-9_]+=/) { sub(/=.*/, "", line); print line }
        }
    ' "$1" | LC_ALL=C sort -u
}

GONE=""
for k in $( old_keys "${OLD_SAMPLE}" ); do
    case "${k}" in
        node_*|guest_*|names_*) continue ;;
    esac
    case " ${CONF_FLEET_KEYS} " in
        *" ${k} "*) ;;
        *) GONE="${GONE} ${k}" ;;
    esac
done
t_is "${GONE}" "" \
    "every fleet key the previous release documented is still in the vocabulary"

# And the mutation: a key that really is gone.
GONE=""
for k in $( old_keys "${OLD_SAMPLE}" ) exorcism; do
    case "${k}" in
        node_*|guest_*|names_*) continue ;;
    esac
    case " ${CONF_FLEET_KEYS} " in
        *" ${k} "*) ;;
        *) GONE="${GONE} ${k}" ;;
    esac
done
t_is "${GONE}" " exorcism" \
    "mutation: a key the previous release had and this one does not is caught"

# ---------------------------------------------------------------------------
# 3. The one shape whose verdict changed, and the reason, by name
# ---------------------------------------------------------------------------

t_rc 0 "the changed-verdict fixture is committed too" -- test -r "${OLD_ARMED}"

t_rc 1 "a v0.2.0-valid configuration arming a node with no carp_interface is REFUSED here" -- \
    sh "${SEANCE}" config --file "${OLD_ARMED}" --check

OUT=$( sh "${SEANCE}" config --file "${OLD_ARMED}" --check 2>&1 )
t_like "${OUT}" 'auto_promote names alpha, and bravo resolves no carp_interface' \
    "and the refusal names the node, the arming and the missing key"
t_like "${OUT}" 'no transition can ever wake this node' \
    "and says what the consequence would have been: automation that is deaf"

# The same file with the one key an upgrade has to add is accepted again, which
# is what makes the refusal a migration rather than a wall.
sed -e 's/^node_bravo_auto_promote=alpha$/node_bravo_carp_interface=vtnet0\nnode_bravo_auto_promote=alpha/' \
    "${OLD_ARMED}" > "${DIR}/migrated.conf"
t_stdout_is "PASS" "adding the node's carp_interface is the whole migration" -- \
    sh "${SEANCE}" config --file "${DIR}/migrated.conf" --check

# ---------------------------------------------------------------------------
# 4. The upgrade document says so, where an operator upgrading will read it
# ---------------------------------------------------------------------------
#
# Source-as-data, and the point of it: a validator rule that is not in the
# upgrade note is a rule a fleet meets at three in the morning. If a later
# release adds another one, row 3 above changes and this row is what makes
# somebody write it down.

UPGRADE=$( awk '/^## 2\. Upgrade/, /^## 3\./' "${T_ROOT}/docs/INSTALL.md" )
t_isnt "${UPGRADE}" "" "docs/INSTALL.md has an upgrade section to check"
t_like "${UPGRADE}" 'config --check' \
    "and it tells the operator to run config --check as part of the upgrade"
t_like "${UPGRADE}" 'carp_interface' \
    "and names the one rule that has changed verdict since v0.2.0"

# The two files an upgrade leaves behind, because they are COPIES of the
# checkout and a pull does not move a copy. Both changed at v0.5.0, and both
# were broken before it -- an operator who does not re-install them keeps a
# boot gate that gates nothing and a crontab line that replicates nothing.
t_like "${UPGRADE}" 'rc\.d/seance_gate' \
    "and tells the operator to re-install the rc(8) unit, which a pull does not move"
t_like "${UPGRADE}" 'render cron' \
    "and to re-render the crontab line, which changed with it"

# ---------------------------------------------------------------------------
# 5. The state a previous release left on the disk is still read
# ---------------------------------------------------------------------------
#
# Written here in the previous release's own formats, by hand, rather than by
# calling this release's writers -- a writer checked against itself proves
# nothing about an upgrade.

STATE="${DIR}/state"
mkdir -p "${STATE}/lag"
SEANCE_STATE_DIR="${STATE}"
export SEANCE_STATE_DIR

# v0.2.0 lag record: "<replica_ts|-> <tick_epoch> <rc>", one line, space
# separated (lib/repl.subr, repl_lag_write).
printf '20260101T000000Z 1767225600 0\n' > "${STATE}/lag/web01.bravo"
t_stdout_is "20260101T000000Z 1767225600 0" \
    "a lag record the previous release wrote is read unchanged" -- \
    repl_lag_read web01 bravo

# v0.2.0 placement record: "<guest><TAB><home>" per line (lib/gate.subr).
printf 'web01\talpha\n' > "${STATE}/placement"
t_stdout_is "alpha" \
    "a placement record the previous release wrote still names the guest's home" -- \
    placement_home web01

# v0.2.0 succession record: five tab-separated fields, appended
# (lib/promote.subr, promote_record). Nothing in seance parses it -- it is the
# account an operator reads -- so what is asserted is that this release APPENDS
# to it rather than replacing it, which is the property "append-only" means.
printf 'web01\talpha\tbravo\t20260101T000000Z\tfence:ipmi\n' > "${STATE}/succession.log"
BEFORE=$( wc -l < "${STATE}/succession.log" | tr -d ' ' )
printf 'db01\talpha\tbravo\t20260101T001000Z\tfailback\n' >> "${STATE}/succession.log"
t_is "$( wc -l < "${STATE}/succession.log" | tr -d ' ' )" "$(( BEFORE + 1 ))" \
    "and a succession log keeps the records the previous release appended to it"
t_like "$( head -1 "${STATE}/succession.log" )" 'fence:ipmi$' \
    "the older record's evidence field is untouched by anything this release does"

t_done
