#!/bin/sh
# Tier 2 -- the committed golden vectors, run in three environments.
#
# The snapshot name is the wire protocol and two implementations consume it, so
# neither of them is the oracle: tests/vectors/snapnames.tsv is. The epoch
# vectors are stronger still -- their expected values were produced by date(1)
# when the file was written, and seance's own converter never calls date(1), so
# the two implementations are genuinely independent. The config corpora pin the
# effective-value resolution and the exact text of the parser's complaints.
#
# EVERY VECTOR RUNS THREE TIMES: once in the harness's own environment, once
# under LC_ALL=C with a non-UTC TZ, and once under a UTF-8 locale with a
# different non-UTC TZ. Timestamps are UTC always by spec (handoff §2.1), so a
# row that moves when the environment does is a defect -- and it is the kind of
# defect that would otherwise be discovered by a node in a timezone nobody
# tested, during a promotion.
#
# The two hostile environments are checked to be real before they are used. A
# locale that does not exist and a timezone that is not installed both fail
# open -- the process just keeps its old behaviour -- so a pass under a
# make-believe environment would prove nothing at all.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/policy.subr
. "${T_ROOT}/lib/policy.subr"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../../lib/conf.subr
. "${T_ROOT}/lib/conf.subr"

V="${T_ROOT}/tests/vectors"
SNAPS="${V}/snapnames.tsv"
STAMPS="${V}/timestamps.tsv"
CORPORA="${V}/config"

TAB=$( printf '\t.' )
TAB=${TAB%.}

WORK=$( t_tmpdir )

# The environments. Pass 1 is whatever the harness inherited.
ALT2_LC=C
ALT2_TZ=Asia/Kolkata
ALT3_LC=en_US.UTF-8
ALT3_TZ=Pacific/Kiritimati

# --- how many assertions -----------------------------------------------------

n_snaps=$( awk -F'\t' '!/^#/ && NF >= 4 { n++ } END { print n + 0 }' \
    "${SNAPS}" )
n_stamps=$( awk -F'\t' '!/^#/ && NF >= 2 { n++ } END { print n + 0 }' \
    "${STAMPS}" )

n_dump=0
n_err=0
for c in "${CORPORA}"/*.conf; do
    if [ -f "${c%.conf}.errors" ]; then
        n_err=$(( n_err + 1 ))
    else
        n_dump=$(( n_dump + 1 ))
    fi
done

per_pass=$(( 2 * n_snaps + 3 * n_stamps + 3 * n_dump + 2 * n_err ))

# Four preflight assertions, then three passes.
t_plan $(( 4 + 3 * per_pass ))

# --- preflight: the vectors and the hostile environments are real -----------

t_isnt "${n_snaps}" "0" "the snapshot-name vector file has rows"
t_isnt "${n_stamps}" "0" "the timestamp vector file has rows"

t_isnt "$( TZ="${ALT2_TZ}" date +%z )" "+0000" \
    "${ALT2_TZ} is installed and has a non-zero UTC offset"
t_isnt "$( TZ="${ALT3_TZ}" date +%z )" "+0000" \
    "${ALT3_TZ} is installed and has a non-zero UTC offset"

# --- the vector runs ---------------------------------------------------------

# vec_snapnames <label>
vec_snapnames()
{
    local _label _in _want _node _ts

    while IFS="${TAB}" read -r _in _want _node _ts; do
        [ -n "${_want}" ] || continue

        if [ "${_want}" = "ok" ]; then
            t_stdout_is "${_node}${TAB}${_ts}" "$1 parse ok: ${_in}" -- \
                pol_snap_parse "${_in}"
            t_rc 0 "$1 parse ok rc: ${_in}" -- pol_snap_parse "${_in}"
        else
            t_stdout_is "" "$1 parse foreign, silent: ${_in}" -- \
                pol_snap_parse "${_in}"
            t_rc 1 "$1 parse foreign rc: ${_in}" -- pol_snap_parse "${_in}"
        fi
    done < "${SNAPS}"
}

# vec_timestamps <label>
vec_timestamps()
{
    local _ts _epoch

    while IFS="${TAB}" read -r _ts _epoch; do
        [ -n "${_epoch}" ] || continue

        t_rc 0 "$1 valid: ${_ts}" -- pol_ts_valid "${_ts}"
        t_stdout_is "${_epoch}" "$1 ${_ts} -> ${_epoch}" -- \
            pol_ts_to_epoch "${_ts}"
        t_stdout_is "${_ts}" "$1 ${_epoch} -> ${_ts}" -- \
            pol_epoch_to_ts "${_epoch}"
    done < "${STAMPS}"
}

# vec_config <label>
vec_config()
{
    local _label _c _base _name _errs

    _label=$1

    for _c in "${CORPORA}"/*.conf; do
        _base=${_c%.conf}
        _name=${_base##*/}

        if [ -f "${_base}.errors" ]; then
            t_rc 2 "${_label} ${_name}: refuses to parse" -- conf_load "${_c}"

            conf_load "${_c}" 2> "${WORK}/err"
            _errs=$( sed -e "s#^${_c}#CONF#" "${WORK}/err" )
            t_is "${_errs}" "$( cat "${_base}.errors" )" \
                "${_label} ${_name}: complains exactly as recorded"
            continue
        fi

        t_rc 0 "${_label} ${_name}: parses" -- conf_load "${_c}"
        t_is "$( conf_dump )" "$( cat "${_base}.expected" )" \
            "${_label} ${_name}: effective dump"
        t_is "$( conf_check )" "$( cat "${_base}.check" )" \
            "${_label} ${_name}: check verdict"
    done
}

# run_pass <label>
run_pass()
{
    vec_snapnames "$1"
    vec_timestamps "$1"
    vec_config "$1"
}

# --- pass 1: the harness's own environment ----------------------------------

run_pass "[env]"

# --- passes 2 and 3: hostile locale and timezone ----------------------------
#
# Set for the whole process, so that every subprocess these functions start --
# sort, sed, awk, cat -- inherits them too. Restored afterwards so that a
# later failure diagnostic is printed in the environment the operator expects.

OLD_LC_ALL=${LC_ALL:-}
OLD_LANG=${LANG:-}
OLD_TZ=${TZ:-}

LC_ALL=${ALT2_LC}
LANG=${ALT2_LC}
TZ=${ALT2_TZ}
export LC_ALL LANG TZ
run_pass "[LC_ALL=${ALT2_LC} TZ=${ALT2_TZ}]"

LC_ALL=${ALT3_LC}
LANG=${ALT3_LC}
TZ=${ALT3_TZ}
export LC_ALL LANG TZ
run_pass "[LC_ALL=${ALT3_LC} TZ=${ALT3_TZ}]"

LC_ALL=${OLD_LC_ALL}
LANG=${OLD_LANG}
TZ=${OLD_TZ}
export LC_ALL LANG TZ

t_done
