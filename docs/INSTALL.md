# Installing, upgrading and uninstalling seance

Everything here follows from `docs/cbsd-module-notes.md` — read that first if a
step here surprises you; every claim in it cites the CBSD 15.0.9 source or a
capture, and this document does not repeat the citations, only the procedure
they support.

**Nothing here is automatic**, on purpose (design §13, decision D-1): a module
that quietly wired itself into a node's boot path would be a module nobody
trusted. Every step below is a command an operator types, and `seance verify`
is how the last one is checked.

## 1. Install

The repository root *is* the module directory (D-1), so a clone into place is
the whole of "downloading" seance:

```sh
git clone <this repo> /usr/local/cbsd/modules/seance.d
```

**It must be a real directory, not a symlink.** `cbsd module mode=list`
enumerates modules with `find ... -type d` — a symlinked module directory is
invisible to it, even though every verb still works (`message.txt` says the
same). A `git clone` already produces a real directory; nothing further to do
here beyond not replacing it with a symlink later.

Enable it, and initialise:

```sh
echo seance.d >> ~cbsd/etc/modules.conf
```

Then run `cbsd initenv`, which is where the one real gotcha in this whole
procedure lives (`docs/cbsd-module-notes.md` §8 defect 6). Interactively, on a
terminal, answering yes to the confirmation:

```sh
cbsd initenv
```

**Unattended, as root, it must be this exact form** — every other spelling
either hangs forever or exits 0 having silently done nothing:

```sh
env NOINTER=1 ALWAYS_YES=1 /usr/local/cbsd/sudoexec/initenv
```

`cbsd initenv inter=0` is the form that LOOKS right and is wrong: it exits 0
having run no stage at all. A bare `cbsd initenv` with no terminal attached
never returns — `getyesno` loops on EOF, and it re-execs itself under
`lockf(1)`, so killing the process you started does not stop the one writing.
Both are observed and cited in `docs/cbsd-module-notes.md` §8 defect 6; do not
rediscover them on a fleet node.

Confirm the module is live:

```sh
cbsd seance version
cbsd help | grep seance
```

### The `cbsd module mode=install` path is not the supported one

CBSD's own installer verb — `cbsd module mode=install seance` — clones
`https://github.com/cbsd/modules-seance.git`, prints `message.txt`, and offers
`mode=upgrade`/`mode=list` afterwards. seance ships the files that convention
expects (`metadata.conf`, `message.txt`) because the convention costs nothing
and will outlive the bug that currently breaks it, but **the bug is real and
is why `git clone` is the supported route (D-1):**

`system/module:78-82` reads `MODULE_DIR` out of `metadata.conf` as *literal
text* — no variable expansion — and then compares its first 23 characters
against the *expanded* string `"${CIX_DISTDIR}/modules"`. Every shipped module
writes `MODULE_DIR="${CIX_DISTDIR}/modules/<name>.d"` (seance's own
`metadata.conf` does too, matching `pkg.d`'s shape exactly), so the literal
comparison always fails:

```
literal MODULE_DIR = [${CIX_DISTDIR}/modules/seance.d]
first 23 chars     = [${CIX_DISTDIR}/modules/]
compared against   = [/usr/local/cbsd/modules]
RESULT: MISMATCH -- cbsd module mode=install would refuse this manifest
```

**What would need to change upstream:** `system/module`'s comparison would
need to expand `MODULE_DIR` before comparing it (or compare against the
literal prefix `"${CIX_DISTDIR}/modules"` instead of the expanded one) — a
one-line fix in CBSD itself, not in anything seance controls. Until that
lands, `metadata.conf` stays byte-for-byte the shape every other module uses
(so that the day it works, seance needs no changes), and installation stays a
plain clone.

`cbsd module mode=list` also refuses to run at all without `git(1)` installed
(`system/module:185-186`) — worth knowing if the very first `cbsd module`
command you try on a fresh node fails with "no such git", since it is true of
`mode=list` too and has nothing to do with seance.

## 2. Upgrade

```sh
cd /usr/local/cbsd/modules/seance.d
git pull
env NOINTER=1 ALWAYS_YES=1 /usr/local/cbsd/sudoexec/initenv
```

The `initenv` re-run is not optional even though the module was already
enabled: it is what stage 9 uses to reconcile `ObsoleteFiles` (see below) and
what re-links the verb if the wrapper's path ever changed. `cbsd seance
version` is the check that the upgrade actually took.

**`ObsoleteFiles`** is the convention a module uses to retire a file a
previous version shipped — seance carries one in the module root for the same
reason `metadata.conf` stays in the standard shape: the convention is free and
will outlive the bug under it. On 15.0.9, stage 9 sources it from
`${workdir}/modules/<name>.d/ObsoleteFiles` (`sudoexec/initenv:1411-1412`),
which is `${workdir}/modules` — the directory that holds only the verb
symlinks, never a `<name>.d/` subdirectory. The file it wants is at
`${CIX_DISTDIR}/modules/seance.d/ObsoleteFiles` instead, so on this CBSD
version an upgrade never actually deletes a retired file through this
mechanism; `docs/cbsd-module-notes.md` §8 defect 4 has the citations. A file
`ObsoleteFiles` names is stale, not gone — check for it by hand after an
upgrade that retired something.

## 3. Uninstall

Remove the `seance.d` line from `~cbsd/etc/modules.conf` by hand, then:

```sh
env NOINTER=1 ALWAYS_YES=1 /usr/local/cbsd/sudoexec/initenv
```

Stage 8 removes the verb symlink (`${workdir}/modules/seance`) and clears
`mod_seance_enabled` from `${workdir}/nc.inventory`; the module's own state
(`${workdir}/var/db/seance`, `${workdir}/var/run/seance`) and its config
(`${workdir}/etc/seance.conf`) are left alone — initenv does not delete data,
and neither does this procedure. Remove the checkout
(`/usr/local/cbsd/modules/seance.d`) only after `cbsd seance version` fails
the way an absent module should.

**What the clone did not enable by itself still has to be removed by hand**,
because nothing here was installed automatically either:

```sh
rm -f /usr/local/bin/seance                      # the PATH link, §5 below
sysrc seance_gate_enable=NO
service seance_gate stop 2>/dev/null || true
rm -f /usr/local/etc/rc.d/seance_gate
rm -f /usr/local/etc/cron.d/seance /etc/cron.d/seance
rm -f /usr/local/etc/devd/seance.conf /etc/devd/seance.conf
service devd restart      # only if a devd rule was actually removed
```

A node mid-uninstall is a node `seance verify` on a peer will start reporting
as unreachable or configuration-diverged — that is correct, not a bug in
`verify`; finish the removal on every node the fleet still expects to hear
from, or take the node out of every peer's configuration too.

## 4. Put the dispatcher on the mesh's `PATH`

One node runs `seance placement` on another over ssh, and an ssh session gets
the *login* `PATH`, not `cbsdsh`'s:

```sh
ln -s /usr/local/cbsd/modules/seance.d/bin/seance /usr/local/bin/seance
ssh <peer> seance placement            # the test that it worked
```

Without this link every peer reads as silent to the node asking, and the
resurrection gate treats "nobody answered" as "withhold the whole estate" —
correct behaviour, arriving for the wrong reason. Do this on every node before
trusting `gate` or `promote` on any of them.

## 5. Install the boot gate

`rc.d/seance_gate` withholds a returning node's estate until the living peers
have been asked (design §8), and it is **disabled by default** — a unit that
started withholding guests the moment the module landed would be a surprise:

```sh
cp /usr/local/cbsd/modules/seance.d/rc.d/seance_gate /usr/local/etc/rc.d/
sysrc seance_gate_enable=YES
service seance_gate onestart          # try it now, not at the next reboot
```

It is ordered `BEFORE: cbsdd`, the only ordering that gets in front of the
estate coming up (the autostart is not its own rc(8) unit; it starts inside
`cbsdd`'s prestart). `docs/RUNBOOK-failback.md` is what to read the first time
it actually withholds something.

## 6. Schedule replication: the cron line

`seance repl` is a cron target, not a daemon. Render the line this node
expects and install it where `cron(8)` reads modularised fragments — seance
ships from ports/packages territory, so `verify` names the third-party
directory first and accepts either:

```sh
seance verify --render cron > /usr/local/etc/cron.d/seance
```

`seance verify` (no arguments) checks this on every subsequent run — one of
its seven checks is exactly "does a crontab fragment cron actually reads carry
this line" — so a missed or hand-edited install shows up as a `WARN` rather
than as a fleet that silently stopped replicating.

## 7. CARP and devd, once a node carries a vhid

Skip this section entirely until at least one node's configuration sets
`node_<key>_vhid` (`etc/seance.conf.sample` documents the keys). Once one
does, render and install both halves — the CARP `rc.conf(5)` lines this node
should carry, and the `devd(8)` rule that fires `promote-event` on the
transition:

```sh
seance verify --render carp
seance verify --render devd > /usr/local/etc/devd/seance.conf
service devd restart
```

**seance never writes either file itself, and CARP is not a single fragment
the way cron and devd are.** `verify --render devd` is a complete rule file,
redirected straight into place. `verify --render carp` prints a commented
`rc.conf(5)` fragment that explains itself — read it, then apply each line it
names with `sysrc(8)` (`sysrc ifconfig_<if>_alias0=...`, and so on for every
alias index and for `kld_list`), plus the one setting the rendering calls out
separately because it is not an `ifconfig` alias at all — a `sysctl(8)` OID
for `/etc/sysctl.conf`, which `verify` also wants set immediately with
`sysctl(8)` itself so a reboot is not required to notice it was missed.
`seance verify` (no arguments) is how all of
this gets checked afterwards, on every run: CARP vhids against `ifconfig(8)`
and every `sysrc -v -e -a` alias variable (whichever file each one actually
lives in), the devd rule's presence and content, and whether `devd(8)` itself
is running. A missing devd rule is a `FAIL` when this node's `auto_promote`
actually names the node whose vhid it is, and only a `WARN` otherwise — the
difference between an arrangement somebody is relying on and one that would
merely have lost a notification.

**Automatic promotion needs two more switches on top of all this** — the
fleet key `auto=1` and the node's own `auto_promote` list
(`etc/seance.conf.sample` again) — both off by default, both `seance verify`'s
business to confirm are consistent with what devd can actually fire.

## 8. Check the whole node

```sh
seance verify
```

This is the summary of everything above: the configuration validates, the
mesh answers, clocks agree within `skew_tolerance`, every peer holds the SAME
configuration file, this node's standby parents are still hidden
(`canmount=noauto, mountpoint=none`), the cron line is installed, and — once
arranged — the CARP and devd checks. Run it after every step in this document
that touches a file, and again after every node in the fleet has been through
it: a fleet where every node individually passes `verify` but disagrees with
its peers about the configuration file is exactly the divergence `verify`
exists to catch loudly (design §5, handoff §2.2).

## See also

- `docs/cbsd-module-notes.md` — the citations and captures behind every claim
  above, plus the full list of CBSD 15.0.9 defects seance's adapter works
  around.
- `README.md` — the verb reference, the exit-code contract, and the testing
  portfolio.
- `docs/RUNBOOK-failback.md` — what to do, in order, once a node this
  procedure was run on comes back from being dead.
- `docs/DRILLS.md` — the release-gating drills; `drill-replication` and
  `drill-guest` are the first proof that an installation this document
  produced actually works.
