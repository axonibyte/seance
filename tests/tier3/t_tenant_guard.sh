#!/bin/sh
# Tier 3 -- the tenant guard (TESTING.md §4, design §13).
#
# seance ships with no tenant knowledge in framework code: no site node names,
# no site addresses, no ports-as-literals, no hardware model names, no site
# vocabulary. Everything site-shaped lives in the site's own config file, which
# is not in this repository. The forbidden list lives here, in the test, and
# nowhere else -- a list in a code comment is documentation, a list in a test
# is a contract.
#
# Scanned: seance bin lib drivers rc.d devd cron tools etc LICENSE (whichever
# exist). Not scanned: docs and the spec copies (DESIGN.md, TESTING.md,
# HANDOFF.md), which carry tenant nicknames by decision D-11, and tests/, which
# has to contain the forbidden strings in order to test for them.
#
# Every line is scanned, comments included: a site node name in a comment is
# still tenant knowledge shipped in framework code.
#
# One allowance: the string "Axonibyte" appears in LICENSE, and in file-header
# copyright lines matching exactly
#     Copyright (c) 2026 Axonibyte Innovations, LLC
# Anywhere else it is a violation like any other.
#
# IPv4 literals are forbidden except 127.0.0.1 and 0.0.0.0 -- loopback and
# "any" are protocol constants, not sites.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff §5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SCAN_PATHS="seance bin lib drivers rc.d devd cron tools etc LICENSE"

PROG=$( t_tmpdir )/tenant.awk
cat > "${PROG}" <<'AWK'
BEGIN {
    n = 0
    # Site node names and their variants.
    n++; pat[n] = "hyp2[abc]";                        tok[n] = "site-node"
    # Site vocabulary, on word boundaries so that ordinary words containing
    # these letters (lockcheck, taxbase) are not false positives.
    n++; pat[n] = "(^|[^a-z0-9])axb([^a-z0-9]|$)";    tok[n] = "site-org"
    n++; pat[n] = "(^|[^a-z0-9])okc([^a-z0-9]|$)";    tok[n] = "site-location"
    # Guest names.
    n++; pat[n] = "webdb01";                          tok[n] = "site-guest"
    n++; pat[n] = "crowdeasedev01";                   tok[n] = "site-guest"
    n++; pat[n] = "artifact01";                       tok[n] = "site-guest"
    n++; pat[n] = "bbrunner01";                       tok[n] = "site-guest"
    # Site ssh port as a literal: the seance default is 22.
    n++; pat[n] = "2212";                             tok[n] = "site-port"
    # Pool name: derived from CBSD's workdir at runtime, never written down.
    n++; pat[n] = "zroot";                            tok[n] = "site-pool"
    # Hardware and appliance model names.
    n++; pat[n] = "idrac";                            tok[n] = "site-hardware"
    n++; pat[n] = "h730";                             tok[n] = "site-hardware"
    n++; pat[n] = "hba330";                           tok[n] = "site-hardware"
    n++; pat[n] = "fortigate";                        tok[n] = "site-hardware"
}

{
    low = tolower($0)

    for (i = 1; i <= n; i++) {
        if (low ~ pat[i]) {
            printf "%s:%d: %s: %s\n", FILENAME, FNR, tok[i], $0
        }
    }

    # The vendor name, allowed in LICENSE and in the copyright header line.
    if (low ~ /axonibyte/) {
        if (FILENAME != "LICENSE" &&
            $0 !~ /Copyright \(c\) 2026 Axonibyte Innovations, LLC/) {
            printf "%s:%d: %s: %s\n", FILENAME, FNR, "vendor-name", $0
        }
    }

    # IPv4 literals. Written without interval expressions so that every awk
    # in the FreeBSD base, on the workstation and in the guest, agrees.
    rest = $0
    while (match(rest, /[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?/)) {
        ip = substr(rest, RSTART, RLENGTH)
        if (ip != "127.0.0.1" && ip != "0.0.0.0") {
            printf "%s:%d: %s: %s\n", FILENAME, FNR, "ipv4-literal", $0
        }
        rest = substr(rest, RSTART + RLENGTH)
    }
}
AWK

# guard_files <root>  -- the scanned files, relative to <root>, one per line.
guard_files()
{
    local _root _p _targets

    _root=$1
    _targets=""

    for _p in ${SCAN_PATHS}; do
        [ -e "${_root}/${_p}" ] && _targets="${_targets} ${_p}"
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

# probe <line>  -- run the guard over a scratch tree holding just that line.
probe()
{
    local _dir

    _dir=$( t_tmpdir )
    mkdir -p "${_dir}/lib"
    printf '%s\n' "$1" > "${_dir}/lib/probe.subr"
    guard "${_dir}"
}

t_plan 13

scanned=$( guard_files "${T_ROOT}" | wc -l | tr -d ' ' )
t_isnt "${scanned}" "0" "the tenant guard scans a non-empty file list"

violations=$( guard "${T_ROOT}" )
t_is "${violations}" "" "no tenant strings in module code"

# Mutation check, permanent: plant a site string in a scratch copy of the real
# tree and require the guard to see it.
scratch=$( t_tmpdir )
for p in ${SCAN_PATHS}; do
    [ -e "${T_ROOT}/${p}" ] && cp -R "${T_ROOT}/${p}" "${scratch}/"
done
printf '# default node is hyp2c\n' >> "${scratch}/lib/common.subr"

planted=$( guard "${scratch}" )
t_like "${planted}" '^lib/common\.subr:[0-9]+: site-node: ' \
    "a planted site node name is caught"

# Each class of the forbidden list, caught.
t_like "$( probe 'ssh_port=2212' )" '^lib/probe\.subr:1: site-port: ' \
    "the site ssh port as a literal is caught"
t_like "$( probe 'standby_root=zroot/standby' )" \
    '^lib/probe\.subr:1: site-pool: ' "a literal pool name is caught"
t_like "$( probe '# fence via the iDRAC' )" \
    '^lib/probe\.subr:1: site-hardware: ' \
    "a hardware name is caught, in a comment like anywhere else"
t_like "$( probe 'peer=192.0.2.10' )" '^lib/probe\.subr:1: ipv4-literal: ' \
    "an IPv4 literal is caught"
t_like "$( probe '_g=crowdeasedev01' )" '^lib/probe\.subr:1: site-guest: ' \
    "a site guest name is caught"
t_like "$( probe '# built at axb' )" '^lib/probe\.subr:1: site-org: ' \
    "site vocabulary is caught"

# The exceptions are real exceptions.
t_is "$( probe '_loopback=127.0.0.1' )" "" "127.0.0.1 is allowed"
t_is "$( probe '_any=0.0.0.0' )" "" "0.0.0.0 is allowed"
t_is "$( probe '# Copyright (c) 2026 Axonibyte Innovations, LLC' )" "" \
    "the copyright header line is allowed"
t_like "$( probe '# see the Axonibyte wiki' )" \
    '^lib/probe\.subr:1: vendor-name: ' \
    "the vendor name anywhere else is caught"

t_done
