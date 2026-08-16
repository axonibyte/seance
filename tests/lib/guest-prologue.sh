#!/bin/sh
# Shape-B prologue: prepare a reaper guest before any tier runs.
#
# Run by tests/run.sh when $REAPER_STATE is set, i.e. only inside a reaper
# session. It installs CBSD and asserts the pinned version, so that a silent
# upstream bump shows up as a failed suite rather than as a mystery two tiers
# later (handoff §5, "Shape B CBSD pin").
#
# Exit: 0 ok, 1 the pin is wrong or the install failed, 2 contract error.
set -u

CBSD_PIN="cbsd-15.0.9"

REAPER_OUT=${REAPER_OUT:-}
REAPER_CACHE_PKG=${REAPER_CACHE_PKG:-}

if [ "$( id -u )" -ne 0 ]; then
    echo "guest-prologue: must run as root (it installs packages)" >&2
    exit 2
fi

if [ -z "${REAPER_CACHE_PKG}" ]; then
    # Not a verdict: the cache only makes the second run fast. Loud because a
    # missing cache means the manifest's [build] cache list did not arrive.
    echo "guest-prologue: WARNING: REAPER_CACHE_PKG is unset;" \
        "installing without a package cache" >&2
    pkg install -y cbsd
else
    PKG_CACHEDIR="${REAPER_CACHE_PKG}" pkg install -y cbsd
fi
rc=$?

if [ "${rc}" -ne 0 ]; then
    echo "guest-prologue: FAIL: pkg install -y cbsd exited ${rc}" >&2
    exit 1
fi

# 'pkg info cbsd' prints the whole information block, whose first line happens
# to be the name-version; 'pkg query' prints exactly the field being asserted
# and nothing that could drift into the comparison.
installed=$( pkg query '%n-%v' cbsd )
rc=$?

if [ "${rc}" -ne 0 ]; then
    echo "guest-prologue: FAIL: pkg query '%n-%v' cbsd exited ${rc}" >&2
    exit 1
fi

if [ "${installed}" != "${CBSD_PIN}" ]; then
    echo "guest-prologue: FAIL: CBSD pin drift:" \
        "pkg info cbsd said [${installed}], the suite is pinned to" \
        "[${CBSD_PIN}]. Re-verify the adapter against the new version" \
        "before moving the pin." >&2
    exit 1
fi

echo "guest-prologue: ${CBSD_PIN} installed and pinned"

# A recording, not an assertion: 'cbsd version' needs an initialised workdir
# (cbsd.conf:28-36 reads cbsd_workdir from /etc/rc.conf and exits 1 without
# it), which the prologue deliberately does not create. Its output and its
# exit status are both written down so drift is visible either way.
if [ -n "${REAPER_OUT}" ]; then
    {
        echo "# cbsd version, recorded by tests/lib/guest-prologue.sh"
        echo "# date: $( date -u +%Y-%m-%dT%H:%M:%SZ )"
        echo "# pkg query '%n-%v' cbsd: ${installed}"
        cbsd version 2>&1
        echo "# exit: $?"
    } > "${REAPER_OUT}/cbsd-version.txt"

    pkg info cbsd > "${REAPER_OUT}/pkg-info-cbsd.txt" 2>&1
fi

exit 0
