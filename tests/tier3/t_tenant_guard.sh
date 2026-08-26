#!/bin/sh
# Tier 3 -- the tenant guard (TESTING.md 4, design 13).
#
# seance ships with no tenant knowledge in framework code: no site node names,
# no site addresses, no ports-as-literals, no hardware model names, no site
# vocabulary. Everything site-shaped lives in the site's own config, which is
# not in this repository.
#
# WHERE THE FORBIDDEN LIST LIVES (changed 2026-08-26). It used to live here, in
# this test -- which meant the one file whose job is to keep this site's names
# out of the public repo was itself the largest concentration of them. The list
# is now SITE DATA, held out of the repo at ../site/tenant-tokens.list (or
# wherever $SEANCE_TENANT_TOKENS points). What stays here is the MECHANISM and a
# SYNTHETIC self-test: the scanner, the scan-path contract, and probes built
# from invented tokens (znode0, zguestvm00, ...) that exercise every class
# without naming anything real. Two rules stay literal because they reveal
# nothing site-specific: no bare IPv4 in code, and the vendor name outside the
# LICENSE/copyright line (Axonibyte is the public repo's own owner).
#
# HOW THE REAL LIST IS APPLIED. When the site list is found, the module code,
# the documents, and the test tree are each scanned against it and must come up
# empty. When it is absent (a fresh public checkout), those three scans SKIP
# with a diagnostic and the mechanism tests still run -- unless
# $SEANCE_TENANT_TOKENS_REQUIRED is set, which turns a missing list into a
# failure. The pre-publish gate sets it; a contributor's checkout need not.
#
# Scanned as MODULE code: seance bin lib drivers rc.d devd cron tools etc
# LICENSE, plus the three CBSD module markers at the repo root -- metadata.conf,
# securecmd, message.txt (the gap D-15 left open; a site name in one travels as
# far as in any other shipped file). The DOCUMENT scan (D-169) covers DESIGN.md,
# HANDOFF.md, TESTING.md, README.md and docs, where a scope=code token (a public
# product the fence docs name openly) is allowed but every other token is not.
# The TEST scan covers tests/: a real node, guest or pool name has no business
# in a fixture when a generic one tests the same thing (two fixtures had carried
# real names as sample data until they were scrubbed and this scan was added).
#
# The token file's format is documented in the file itself; each line is
#     <label>  <scope>  <ere-regex>          scope: all | code
# and every source line is lower-cased before matching.
#
# shellcheck disable=SC3043
#   'local' is not in POSIX sh but is implemented by FreeBSD /bin/sh (sh(1),
#   "local"); seance targets FreeBSD sh and nothing else (handoff 5).
set -u

# shellcheck source-path=SCRIPTDIR
# shellcheck source=../lib/harness.subr
. "$( dirname "$( realpath "$0" )" )/../lib/harness.subr"

SCAN_PATHS="seance bin lib drivers rc.d devd cron tools etc LICENSE
metadata.conf securecmd message.txt"
DOC_SCAN_PATHS="DESIGN.md HANDOFF.md TESTING.md README.md docs"
GUARD_SELF="tests/tier3/t_tenant_guard.sh"

# --- the one parameterised scanner -----------------------------------------
#
# Named tokens come from the file named by -v TOKENS (empty -> none). -v DOCS=1
# drops scope=code tokens (the document allowance). -v WANT_IPV4 / -v WANT_VENDOR
# turn on the two literal rules. Nothing site-specific is baked in here.
SCANNER=$( t_tmpdir )/tenant-scan.awk
cat > "${SCANNER}" <<'AWK'
BEGIN {
    n = 0
    if (TOKENS != "") {
        while ((getline _l < TOKENS) > 0) {
            gsub(/\r/, "", _l)
            if (_l ~ /^[ \t]*#/) continue
            sub(/^[ \t]+/, "", _l); sub(/[ \t]+$/, "", _l)
            if (_l == "") continue
            nf = split(_l, _f, /[ \t]+/)
            if (nf < 3) continue
            _rx = _f[3]
            for (_j = 4; _j <= nf; _j++) _rx = _rx " " _f[_j]
            n++; tok[n] = _f[1]; scope[n] = _f[2]; pat[n] = _rx
        }
        close(TOKENS)
    }
}
{
    low = tolower($0)

    for (i = 1; i <= n; i++) {
        if (DOCS && scope[i] == "code") continue
        if (low ~ pat[i])
            printf "%s:%d: %s: %s\n", FILENAME, FNR, tok[i], $0
    }

    if (WANT_VENDOR && low ~ /axonibyte/ &&
        $0 !~ /Copyright \(c\) 2026 Axonibyte Innovations, LLC/)
        printf "%s:%d: %s: %s\n", FILENAME, FNR, "vendor-name", $0

    if (WANT_IPV4) {
        rest = $0
        while (match(rest, /[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?\.[0-9][0-9]?[0-9]?/)) {
            ip = substr(rest, RSTART, RLENGTH)
            if (ip != "127.0.0.1" && ip != "0.0.0.0")
                printf "%s:%d: %s: %s\n", FILENAME, FNR, "ipv4-literal", $0
            rest = substr(rest, RSTART + RLENGTH)
        }
    }
}
AWK

# guard_files <root>  -- the module-scanned files, relative to <root>.
guard_files()
{
    local _root _p _targets
    _root=$1; _targets=""
    for _p in ${SCAN_PATHS}; do
        [ -e "${_root}/${_p}" ] && _targets="${_targets} ${_p}"
    done
    [ -n "${_targets}" ] || return 1
    # shellcheck disable=SC2086
    ( cd "${_root}" && find ${_targets} -type f | sort )
}

# doc_files / test_files -- the other two scan sets.
doc_files()
{
    local _root _p _targets
    _root=$1; _targets=""
    for _p in ${DOC_SCAN_PATHS}; do
        [ -e "${_root}/${_p}" ] && _targets="${_targets} ${_p}"
    done
    [ -n "${_targets}" ] || return 1
    # shellcheck disable=SC2086
    ( cd "${_root}" && find ${_targets} -type f | sort )
}

test_files()
{
    local _root
    _root=$1
    [ -d "${_root}/tests" ] || return 1
    # shellcheck disable=SC2086
    ( cd "${_root}" && find tests -type f ! -path "${GUARD_SELF}" | sort )
}

# guard / doc_guard / test_guard <root> <tokens>  -- one line per violation.
guard()
{
    local _root _tok _files
    _root=$1; _tok=$2; _files=$( guard_files "${_root}" ) || return 1
    # shellcheck disable=SC2086
    ( cd "${_root}" && awk -v TOKENS="${_tok}" -v DOCS=0 -v WANT_IPV4=1 -v WANT_VENDOR=1 -f "${SCANNER}" ${_files} )
}

doc_guard()
{
    local _root _tok _files
    _root=$1; _tok=$2; _files=$( doc_files "${_root}" ) || return 1
    # shellcheck disable=SC2086
    ( cd "${_root}" && awk -v TOKENS="${_tok}" -v DOCS=1 -v WANT_IPV4=0 -v WANT_VENDOR=0 -f "${SCANNER}" ${_files} )
}

test_guard()
{
    local _root _tok _files
    _root=$1; _tok=$2; _files=$( test_files "${_root}" ) || return 1
    # shellcheck disable=SC2086
    ( cd "${_root}" && awk -v TOKENS="${_tok}" -v DOCS=0 -v WANT_IPV4=0 -v WANT_VENDOR=1 -f "${SCANNER}" ${_files} )
}

# --- the SYNTHETIC token list: invented names, one per class, that name
# nothing real and let the mechanism be tested on every public checkout. -----
SYNTH=$( t_tmpdir )/synth-tokens.list
cat > "${SYNTH}" <<'EOF'
site-node      all   znode[0-9]
site-org       all   (^|[^a-z0-9])zorg([^a-z0-9]|$)
site-location  all   (^|[^a-z0-9])zloc([^a-z0-9]|$)
site-guest     all   zguestvm00
site-port      all   65123
site-pool      all   zpool00
site-hardware  code  zbmc00
site-hardware  all   zhba00
EOF

# probe <line>  -- run the code scan over a scratch tree holding just that line,
# with the synthetic token list.
probe()
{
    local _dir
    _dir=$( t_tmpdir ); mkdir -p "${_dir}/lib"
    printf '%s\n' "$1" > "${_dir}/lib/probe.subr"
    guard "${_dir}" "${SYNTH}"
}

# --- locate the real site list; decide enforce vs skip vs fail-closed -------
TOKENS_REAL=""
if [ -n "${SEANCE_TENANT_TOKENS:-}" ] && [ -r "${SEANCE_TENANT_TOKENS}" ]; then
    TOKENS_REAL="${SEANCE_TENANT_TOKENS}"
elif [ -r "${T_ROOT}/../site/tenant-tokens.list" ]; then
    TOKENS_REAL="${T_ROOT}/../site/tenant-tokens.list"
fi

# real_scan <fn> <desc>  -- exactly one assertion, whatever the list's state:
# clean when the list is present, a failure when it is REQUIRED but missing, a
# skip otherwise. Keeps the plan count stable across environments.
real_scan()
{
    local _fn _desc _out
    _fn=$1; _desc=$2
    if [ -n "${TOKENS_REAL}" ]; then
        _out=$( "${_fn}" "${T_ROOT}" "${TOKENS_REAL}" )
        t_is "${_out}" "" "${_desc}"
    elif [ -n "${SEANCE_TENANT_TOKENS_REQUIRED:-}" ]; then
        t_is "site tenant list REQUIRED but not found" "" \
            "${_desc} -- list required (SEANCE_TENANT_TOKENS_REQUIRED) but none provided"
    else
        t_diag "site tenant list not found; set SEANCE_TENANT_TOKENS to enforce site names"
        t_is "skip" "skip" "${_desc} -- skipped (no site list on this checkout)"
    fi
}

t_plan 25

# --- the mechanism: the scan sets are a contract, not an implementation detail
scanned=$( guard_files "${T_ROOT}" | wc -l | tr -d ' ' )
t_isnt "${scanned}" "0" "the tenant guard scans a non-empty module file list"

for marker in metadata.conf securecmd message.txt; do
    t_like "$( guard_files "${T_ROOT}" )" "^${marker}\$" \
        "the module marker ${marker} is scanned"
done

# --- the mechanism catches every class (synthetic tokens, nothing real) -----
scratch=$( t_tmpdir )
for p in ${SCAN_PATHS}; do
    [ -e "${T_ROOT}/${p}" ] && cp -R "${T_ROOT}/${p}" "${scratch}/"
done
printf '# default node is znode3\n' >> "${scratch}/lib/common.subr"
printf 'MYDESC="succession for the zloc estate"\n' >> "${scratch}/metadata.conf"
planted=$( guard "${scratch}" "${SYNTH}" )
t_like "${planted}" '^lib/common\.subr:[0-9]+: site-node: ' \
    "a planted site node name is caught"
t_like "${planted}" '^metadata\.conf:[0-9]+: site-location: ' \
    "a planted site string in a module marker is caught"

t_like "$( probe '_port=65123' )"                 '^lib/probe\.subr:1: site-port: '     "a site ssh port token is caught"
t_like "$( probe 'standby_root=zpool00/standby' )" '^lib/probe\.subr:1: site-pool: '     "a site pool token is caught"
t_like "$( probe '# fence via the zbmc00' )"       '^lib/probe\.subr:1: site-hardware: ' "a site hardware token is caught, in a comment like anywhere else"
t_like "$( probe '_g=zguestvm00' )"                '^lib/probe\.subr:1: site-guest: '    "a site guest token is caught"
t_like "$( probe '# built at zorg' )"              '^lib/probe\.subr:1: site-org: '      "a site org token is caught"
t_like "$( probe '# located in zloc' )"            '^lib/probe\.subr:1: site-location: ' "a site location token is caught"

# --- the literal rules (nothing site-specific) ------------------------------
t_like "$( probe '_peer=192.0.2.10' )" '^lib/probe\.subr:1: ipv4-literal: ' "a bare IPv4 literal is caught"
t_is   "$( probe '_loopback=127.0.0.1' )" "" "127.0.0.1 is allowed"
t_is   "$( probe '_any=0.0.0.0' )" "" "0.0.0.0 is allowed"
t_is   "$( probe '# Copyright (c) 2026 Axonibyte Innovations, LLC' )" "" "the copyright header line is allowed"
t_like "$( probe '# see the Axonibyte wiki' )" '^lib/probe\.subr:1: vendor-name: ' "the vendor name anywhere else is caught"

# --- the document scan's shape and its scope=code allowance -----------------
docscratch=$( t_tmpdir )/docs
mkdir -p "${docscratch}/docs"
printf 'The ring puts znode1 first.\n' > "${docscratch}/DESIGN.md"
printf 'The zbmc00 and kin answer chassis power status.\n' > "${docscratch}/docs/fence-drivers.md"
docplanted=$( doc_guard "${docscratch}" "${SYNTH}" )
t_like "${docplanted}" '^DESIGN\.md:1: site-node: ' \
    "a site node name planted in a document is caught"
t_unlike "${docplanted}" 'fence-drivers' \
    "a scope=code token is allowed in the docs (the fence-driver example is not a violation)"
printf 'ssh runs on port 65123 at the site.\n' >> "${docscratch}/docs/fence-drivers.md"
t_like "$( doc_guard "${docscratch}" "${SYNTH}" )" '^docs/fence-drivers\.md:2: site-port: ' \
    "and the allowance does not blanket the file: a scope=all token beside it is still caught"

# --- the test scan catches a real-shaped name dropped into a fixture, while
# THIS file is exempt by EXACT PATH -- it must name the vendor to implement the
# vendor rule, and carries only synthetic tokens, so it would trip on itself.
# Planted fixture and a copy of this file share one scratch tree, so a rename
# that broke the exemption would fail assertion two, not pass silently.
testscratch=$( t_tmpdir )/ts
mkdir -p "${testscratch}/tests/tier1" "${testscratch}/tests/tier3"
printf '#!/bin/sh\n_g=zguestvm00\n' > "${testscratch}/tests/tier1/planted.sh"
cp "${T_ROOT}/${GUARD_SELF}" "${testscratch}/${GUARD_SELF}"
testout=$( test_guard "${testscratch}" "${SYNTH}" )
t_like "${testout}" '^tests/tier1/planted\.sh:2: site-guest: ' \
    "a site guest name planted in a test fixture is caught"
t_unlike "${testout}" 't_tenant_guard\.sh' \
    "and this file is exempt from the test scan by exact path, not tripping on its own vendor mention"

# --- and, against the REAL list when present, the repo is clean -------------
real_scan guard      "no site names in module code"
real_scan doc_guard  "no site names in the documents"
real_scan test_guard "no site names in the test suite"

t_done
