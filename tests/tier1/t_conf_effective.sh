#!/bin/sh
# Tier 1 -- effective values: override, then setting, then default.
#
# Three layers, and the order between them is the whole feature: a per-guest
# override beats the fleet setting, the fleet setting beats the built-in
# default, and a key with no value anywhere says so rather than inventing one.
#
# The derived key is the interesting one. staleness_max, unset, is three times
# the cadence THAT GUEST gets -- not three times the fleet cadence. A guest
# replicated every five minutes should be called dead after fifteen; deriving
# from the fleet default would give it forty-five and make the most tightly
# replicated guest the slowest to be noticed as gone.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/conf.subr
. "${T_ROOT}/lib/conf.subr"

DIR=$( t_tmpdir )

t_plan 64

# --- defaults, with nothing set at all ------------------------------------

printf '' > "${DIR}/bare.conf"
conf_load "${DIR}/bare.conf" || t_diag "bare.conf failed to load"

while IFS='|' read -r key want; do
    case "${key}" in
        ''|'#'*) continue ;;
    esac
    t_stdout_is "${want}" "default ${key}" -- conf_effective "${key}"
done <<'TABLE'
cadence|900
retention_recent|14400
retention_hourly|172800
skew_tolerance|120
debounce|45
fence_timeout|60
ssh_user|root
ssh_port|22
staleness_max|2700
TABLE

for key in notify_cmd witness standby_root ssh_extra_opts; do
    t_rc 1 "no default for ${key}: unset is the answer" -- \
        conf_effective "${key}"
    t_stdout_is "" "and it prints nothing: ${key}" -- conf_effective "${key}"
done

t_rc 1 "a key that is not in the vocabulary has no effective value" -- \
    conf_effective nosuchkey

# --- the fleet layer beats the default ------------------------------------

cat > "${DIR}/fleet.conf" <<'EOF'
cadence=300
ssh_port=2222
notify_cmd=/usr/local/bin/notify --loud
EOF
conf_load "${DIR}/fleet.conf" || t_diag "fleet.conf failed to load"

t_stdout_is "300" "a fleet setting beats the default" -- conf_effective cadence
t_stdout_is "2222" "so does a fleet port" -- conf_effective ssh_port
t_stdout_is "root" "an unset key still gets its default" -- \
    conf_effective ssh_user
t_stdout_is "/usr/local/bin/notify --loud" \
    "a key with no default takes the fleet value" -- conf_effective notify_cmd
t_stdout_is "900" "staleness_max follows the fleet cadence" -- \
    conf_effective staleness_max

# --- the guest layer beats the fleet --------------------------------------

cat > "${DIR}/guests.conf" <<'EOF'
cadence=900
staleness_max=4000
node_alpha_nodename=alpha.example.net
node_alpha_mgmt=alpha-mgmt.example.net
node_alpha_heir=bravo
node_bravo_nodename=bravo.example.net
node_bravo_mgmt=bravo-mgmt.example.net
node_bravo_heir=alpha
guest_db_cadence=300
guest_web_heir=alpha
guest_web_heir2=bravo
guest_slow_cadence=3600
guest_slow_staleness_max=5400
EOF
conf_load "${DIR}/guests.conf" || t_diag "guests.conf failed to load"

t_stdout_is "300" "a guest override beats the fleet setting" -- \
    conf_effective cadence db
t_stdout_is "900" "a guest with no override inherits the fleet setting" -- \
    conf_effective cadence web
t_stdout_is "900" "an unnamed guest is the fleet view" -- conf_effective cadence
t_stdout_is "4000" "a guest inherits an explicit fleet staleness_max" -- \
    conf_effective staleness_max db
t_stdout_is "5400" "a guest may override staleness_max too" -- \
    conf_effective staleness_max slow
t_stdout_is "alpha" "a guest heir override is readable" -- \
    conf_effective heir web
t_stdout_is "bravo" "and its second heir" -- conf_effective heir2 web
t_rc 1 "a guest with no heir override has none" -- conf_effective heir db

# Only the four documented keys are guest-overridable; asking for any other
# key with a guest name falls straight through to the fleet view, because
# there is no such thing as a per-guest ssh_port.
t_stdout_is "22" "ssh_port is not guest-overridable and falls through" -- \
    conf_effective ssh_port db

# --- the derivation is per guest ------------------------------------------

cat > "${DIR}/derive.conf" <<'EOF'
cadence=900
guest_fast_cadence=300
guest_slow_cadence=3600
EOF
conf_load "${DIR}/derive.conf" || t_diag "derive.conf failed to load"

t_stdout_is "2700" "fleet staleness_max is three fleet cadences" -- \
    conf_effective staleness_max
t_stdout_is "900" "a fast guest's staleness_max is three of ITS cadences" -- \
    conf_effective staleness_max fast
t_stdout_is "10800" "and a slow guest's is three of its own" -- \
    conf_effective staleness_max slow

# --- nodes, guests, ordering and identity ---------------------------------

cat > "${DIR}/order.conf" <<'EOF'
node_charlie_nodename=charlie.example.net
node_charlie_mgmt=charlie-mgmt.example.net
node_alpha_nodename=alpha.example.net
node_alpha_mgmt=alpha-mgmt.example.net
node_charlie_heir=alpha
node_bravo_nodename=bravo.example.net
node_bravo_mgmt=bravo-mgmt.example.net
guest_zeta_cadence=60
guest_alpha01_cadence=120
names_charlie=charlie-01.example.net
EOF
conf_load "${DIR}/order.conf" || t_diag "order.conf failed to load"

t_stdout_is "charlie
alpha
bravo" "nodes come back in order of first appearance" -- conf_nodes
t_stdout_is "3" "and are counted" -- conf_node_count
t_stdout_is "zeta
alpha01" "guests come back in order of first appearance" -- conf_guests

t_stdout_is "bravo" "conf_self_key maps a nodename to its key" -- \
    conf_self_key bravo.example.net
t_stdout_is "charlie" "conf_self_key finds the first node too" -- \
    conf_self_key charlie.example.net
t_rc 1 "conf_self_key refuses a nodename no node claims" -- \
    conf_self_key delta.example.net
t_rc 1 "conf_self_key refuses an empty nodename" -- conf_self_key ""
t_rc 1 "conf_self_key does not match a node KEY by accident" -- \
    conf_self_key charlie
t_stdout_is "charlie-01.example.net" "a display name is readable" -- \
    conf_get names_charlie

# --- conf_classify ---------------------------------------------------------

while IFS='|' read -r key want; do
    case "${key}" in
        ''|'#'*) continue ;;
    esac
    if [ "${want}" = "-" ]; then
        t_rc 1 "classify rejects ${key}" -- conf_classify "${key}"
    else
        t_stdout_is "${want}" "classify ${key}" -- conf_classify "${key}"
    fi
done <<'TABLE'
cadence|fleet cadence
ssh_extra_opts|fleet ssh_extra_opts
node_alpha_nodename|node alpha nodename
node_alpha_fence_driver|node alpha fence_driver
node_a1_mgmt|node a1 mgmt
guest_db01_cadence|guest db01 cadence
guest_db01_staleness_max|guest db01 staleness_max
names_alpha|names alpha
node_alpha|-
node_alpha_mgnt|-
node__mgmt|-
node_Alpha_mgmt|-
guest_db01_home|-
guest_db01|-
names_|-
names_Alpha|-
cadance|-
ssh_port_extra|-
TABLE

t_rc 1 "classify rejects an empty key" -- conf_classify ""
t_rc 1 "classify rejects no argument at all" -- conf_classify

t_done
