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

### Run `config --check` on every node, before and after

```sh
seance config --check          # before the pull, and again after it
```

**The validator is allowed to grow rules, and every rule it grows is a
migration.** `seance_load_conf` runs `config --check` before *every* verb, so a
configuration that a previous release accepted and this one does not stops
`repl`, `status`, `verify`, `gate` and `promote` on that node the moment the
checkout moves — on a running fleet, with the automation the operator believed
was armed. Checking before the pull tells you the file was clean; checking
after tells you whether it still is.

**What has changed since v0.2.0 — one rule, and this is all of it.** A node
whose `auto_promote` names a peer must now resolve a `carp_interface`, either
its own (`node_<key>_carp_interface`) or the fleet key. Before, a node with no
vhid of its own could be armed with neither, and nothing could ever make it
CARP MASTER for the corpse's vhid: the automation was switched on and deaf, and
every other check was green (decision D-156, the same failure shape as D-116).
The refusal names the node and the missing key, and the migration is to add the
key:

```
problem: node bravo: auto_promote names alpha, and bravo resolves no
carp_interface (neither node_bravo_carp_interface nor the fleet key): the alias
for that vhid has no interface to live on, so no transition can ever wake this
node
```

Nothing else changed verdict, and no configuration key has been removed:
`tests/tier1/t_conf_upgrade.sh` holds both halves of that promise against the
previous release's own shipped sample, so a future release that adds another
rule has to write the note here before its own suite will pass. The state a
node has already accumulated — `succession.log`, `placement`, the lag records
under `${workdir}/var/db/seance` — is read unchanged and needs no migration at
all; the same test pins each format.

### Re-install the two files the clone does not own

A `git pull` moves the checkout. It does **not** move the copies of the
checkout's files that §5 and §6 told you to put elsewhere, and at v0.5.0 both
of them changed:

```sh
cp /usr/local/cbsd/modules/seance.d/rc.d/seance_gate /usr/local/etc/rc.d/
service seance_gate onestart          # and read what it says

mkdir -p /usr/local/etc/cron.d
seance verify --render cron > /usr/local/etc/cron.d/seance
```

- **`rc.d/seance_gate`.** Before v0.5.0 the unit ran the module's `bin/seance`,
  which rc(8) cannot run at all — so an upgraded node that keeps its old copy
  keeps a boot gate that exits 2 and gates nothing, and says so only in
  `/var/log/messages`. `service seance_gate onestart` after the copy is how you
  see which one you have: `nothing withheld` or a `HELD` line is the new unit
  working; `WARNING: … THE ESTATE HAS NOT BEEN GATED` is the old one.
- **the crontab line.** It named `bin/seance` too, for the same reason and with
  the same result — a node that has been replicating nothing since it was
  installed. `seance verify` reports the stale line as `WARN cron: … does not
  carry the expected line` and prints the one to install, so this is the one
  migration step `verify` will keep reminding you about.

The `devd(8)` rules are unchanged and do not need re-rendering; `seance verify`
says so either way.

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
rm -f /usr/local/bin/seance                      # the PATH link, §4 above
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

## 4. Put the module's verb on the mesh's `PATH`

One node runs `seance placement` on another over ssh, and an ssh session gets
the *login* `PATH`, not `cbsdsh`'s. **Link the module's verb wrapper — the
`seance` file at the module root — and not `bin/seance` under it:**

```sh
ln -s /usr/local/cbsd/modules/seance.d/seance /usr/local/bin/seance
ssh <peer> seance placement            # the test that it worked
```

The distinction is not cosmetic and it is the one this document got wrong
until M5. `bin/seance` is the plain dispatcher, and it learns which node it is
on — where the configuration is, where the state directory is — only from the
variables the wrapper exports (`docs/cbsd-module-notes.md` §2, decision D-2).
Linked that way, `ssh <peer> seance placement` answers `no config file: set
SEANCE_CONF, or run under CBSD` and exits 2. Every peer then reads as **silent**
to the node asking — which is not "no claim" but "cannot tell", so the gate
withholds whole estates, `promote` aborts and `failback` refuses, fleet-wide,
from the install instructions alone. Do this on every node before trusting
`gate` or `promote` on any of them, and run the `ssh` line above as the proof.

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

**`service seance_gate onestart` is not an optional flourish**, and this is
what it is for: the unit finds seance through `${workdir}/modules/seance`, the
verb symlink §1's `initenv` planted, and until M5 it walked past that symlink
to `bin/seance` underneath — which, run from rc(8) with no environment, exits 2
and gates nothing. `onestart` is where an operator sees that in one line
instead of at the first reboot after a real death. Expect it to print either
`nothing withheld` (exit 0) or a `HELD` line per guest (exit 1); a `WARNING:
… THE ESTATE HAS NOT BEEN GATED` is the one answer to stop on.

## 6. Schedule replication: the cron line

`seance repl` is a cron target, not a daemon. Render the line this node
expects and install it where `cron(8)` reads modularised fragments — seance
ships from ports/packages territory, so `verify` names the third-party
directory first and accepts either:

```sh
mkdir -p /usr/local/etc/cron.d
seance verify --render cron > /usr/local/etc/cron.d/seance
```

**The `mkdir` is not tidiness.** `/usr/local/etc/cron.d` is a directory
`cron(8)` reads and nothing on a stock FreeBSD node creates; without it the
redirect fails with `No such file or directory`, nothing is installed, and the
operator has no reason to think otherwise. (`/etc/cron.d` does exist, and
`verify` accepts a fragment in either — but the third-party directory is the
one seance ships into.)

The rendered line names **the platform's own verb**, not `bin/seance`:

```
*/15 * * * * root /usr/local/bin/cbsd seance repl
```

which is the same distinction §4 makes about the mesh link, and it is here for
the same reason — cron gives a job `PATH`, `HOME`, `LOGNAME` and `SHELL` and
nothing else, and the plain dispatcher cannot find its configuration in that.
Until M5 the rendering named `bin/seance`, so a freshly installed node
replicated nothing, for ever, while `verify` reported the crontab line as
correctly installed.

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
