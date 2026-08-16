# CBSD module notes (M0)

What a CBSD external module is, how it is discovered, dispatched, configured
and packaged — established by reading CBSD 15.0.9's own sh source and by
running it, not from memory.

**Every claim below cites either `/usr/local/cbsd/<file>:<line>` (CBSD 15.0.9,
byte-identical on the workstation and in the guest) or a capture in `out/m0/`
from the M0 spike.** `out/` is a reaper results directory and is not committed;
the quotations here are the parts that matter. Anything not observed is marked
**UNVERIFIED** and nothing in seance's design depends on it.

Spike substrate: a reaper `freebsd-15.1` session, FreeBSD 15.1-RELEASE-p2
(`releng/15.1-n283596-aadd58dddcbc`), OpenZFS `zfs-2.4.2-1`, `cbsd-15.0.9` from
pkg, run as root, workdir `/tank/state/cbsd`, nodename `alpha`
(`out/m0/00-environment.txt`).

---

## 1. Layout and discovery

A module is a directory `${CIX_DISTDIR}/modules/<name>.d/` — `CIX_DISTDIR` is
`/usr/local/cbsd` (`cbsd.conf:24`), `distmoduledir` is
`${CIX_DISTDIR}/modules` (`cbsd.conf:81`). Two files make it a module:

- **`metadata.conf`** — `CBSDMODULE=`, `MODULE_DIR=`, `MYDESC=`. Read by
  `cbsd module` only (`system/module:45,67`); its presence is also the
  signature `list_module` looks for (`system/module:148`). Specimens:
  `modules/pkg.d/metadata.conf`, `modules/zfsinstall.d/metadata.conf`.
- **`securecmd`** — a shell fragment appending verb names to `SECCMD`, sourced
  by `initenv` stage 8 (`sudoexec/initenv:1388`). Specimen:
  `modules/pkg.d/securecmd`.

Optional: `ObsoleteFiles` (an `OLD_FILES=` list that initenv stage 9 means to
consume, `sudoexec/initenv:1403-1421` — but see defect 4), `message.txt`
(printed once after `cbsd module mode=install`, `system/module:133-136`), and
an `etc-sample/` directory by convention (`modules/pkg.d/etc-sample/`).

seance's repository root **is** the module directory (decision D-1), so a
`git clone` into `/usr/local/cbsd/modules/seance.d` is a complete install.

**Discovery is `$PATH`, not a registry.** `cbsd.conf:122` puts
`${moduledir}` — `${workdir}/modules` (`cbsd.conf:79`) — first on the PATH that
`cbsdsh` execs against, ahead of CBSD's own `bin`, `sbin`, `tools` and the
per-emulator directories. A module verb therefore *overrides* a CBSD command of
the same name. There is **no two-level dispatch**: `cbsd seance version` is
`cbsd` exec'ing the program `seance` with the argument `version`, and nothing
in CBSD knows that `version` belongs to `seance`.

Enabling is two steps, and neither is automatic:

1. add the *directory name* — `seance.d`, with the suffix — as a line in
   `${workdir}/etc/modules.conf` (`sudoexec/initenv:1386`,
   `system/module:151-159`);
2. re-run `initenv`, whose stage 8 does the linking.

```
$ cat /tank/state/cbsd/etc/modules.conf
pkg.d
bsdconf.d
zfsinstall.d
seance.d
```
— `out/m0/03c-stage8-result.txt`

Stage 8 (`sudoexec/initenv:1354-1401`) sources each enabled module's
`securecmd` and, for every word in `SECCMD`, symlinks
`${distmoduledir}/<name>.d/<verb>` into `${moduledir}/<verb>`
(`:1391-1394`), then records the module in the node inventory
(`:1398-1399`). It also *removes* links whose module is no longer listed
(`:1369-1383`), so deleting the `modules.conf` line and re-running initenv is
the uninstall.

```
$ readlink /tank/state/cbsd/modules/seance
/usr/local/cbsd/modules/seance.d/seance

$ grep -n seance /tank/state/cbsd/nc.inventory
55:mod_seance_enabled="YES"
```
— `out/m0/03c-stage8-result.txt`

**A module directory may be a symlink, with one consequence.** The spike
installed `seance.d` as a symlink to the reaper working tree; every verb worked
(the wrapper resolves `realpath($0)`), but `cbsd module mode=list` did not list
it, because `list_module` enumerates with `find … -type d`
(`system/module:146`) and a symlink to a directory is not `-type d`:

```
$ cbsd module mode=list          # seance.d installed as a symlink
MODULE              STATUS
bsdconf              on
cbsd_queue           off
pkg                  on
zfsinstall           on

$ cbsd module mode=list          # same tree, installed as a real directory
MODULE              STATUS
bsdconf              on
cbsd_queue           off
pkg                  on
seance               on
zfsinstall           on
```
— `out/m0/05-module-list-copy.txt`

So: a symlinked module works but is invisible to `mode=list`. Install by clone
or copy on a real node.

## 2. Verb registration and dispatch

A verb is an executable file at the module directory's root, named exactly as
in `securecmd`, with `#!/usr/local/bin/cbsd` as its interpreter — it runs under
`cbsdsh`, CBSD's own shell, not `/bin/sh`. The header assigns the variables
`cbsdsh` reads, then sources CBSD's subroutines and calls `cixinit`
(`modules/pkg.d/pkg:1-52`):

```sh
#!/usr/local/bin/cbsd
CBSDMODULE="seance"
CIXARG=""                 # required args; a missing one is an error
CIXOPTARG="mode"          # optional args, initialised empty
MYDESC="…"                # one line, shown by 'cbsd help' and --desc
ADDHELP="…"               # long help, shown by --help
. ${subrdir}/nc.subr
. ${tools}
cixinit
```

`cixinit`, `substr`, `capture`, `cbsdsqlro` and `cbsdsqlrw` are **builtins of
the `cbsd` binary**, not shell functions: they appear in no file under
`/usr/local/cbsd`, and in the binary's strings —

```
$ strings /usr/local/bin/cbsd | grep -E '^(cixinit|cbsdsqlro|cbsdsqlrw|substr|capture|readconf|err)$'
capture
cbsdsqlro
cbsdsqlrw
cixinit
substr
```
— `out/m0/01-cbsdsh-builtins.txt`. (`readconf` and `err` *are* shell functions:
`subr/nc.subr:697`, `:59`.) The older equivalent is the shell function `init`
(`subr/nc.subr:122`), driven by `MYARG`/`MYOPTARG` and reached through
`. ${cbsdinit}` (`subr/cbsdinit.subr`); `modules/zfsinstall.d/zfsinstall:1-16`
is a specimen. New code should use the `CIXARG`/`cixinit` form.

`--help` and `--desc` are intercepted before the verb's body runs, and print
`MYDESC`, the argument lists and `ADDHELP` (`subr/nc.subr:131-170` for the
`init` path; `cixinit` behaves the same, observed below). Both were served
without seance's own dispatcher being reached:

```
$ cbsd seance --desc
Guest succession: replication, death detection, fencing, promotion

$ cbsd help | grep -i seance
seance                 --  Guest succession: replication, death detection, fencing, promotion
```
— `out/m0/04-verb-dispatch.txt`

**Arguments.** `key=value` words named in `CIXARG`/`CIXOPTARG` become shell
variables. Everything else lands in `CIX_OTHER_ARGS` (`tools/getinfo:13`,
`tools/task:53-60`). That is the whole mechanism behind the `mode=` idiom and
the reason a bare sub-verb works at all. Observed, with seance's dispatcher
temporarily replaced by `env`:

```
$ cbsd seance version           ->  argv: [version]
$ cbsd seance mode=version      ->  argv: [version]
$ cbsd seance one two three     ->  argv: [one two three]
```
— `out/m0/04c-module-environment.txt`

**A verb's own flags go to `CIX_OTHER_ARGS` in BOTH spellings, and that is the
whole of the trap.** M0 only ever ran verbs with no flags of their own, so it
saw `mode` and `CIX_OTHER_ARGS` as alternatives. They are not. Observed in the
guest with the wrapper's exec line replaced by a `printf` of the two variables
(`out/m1/h-cbsd-args.txt`, CBSD 15.0.9):

```
$ cbsd seance version                       mode=[]        CIX_OTHER_ARGS=[version]
$ cbsd seance mode=version                  mode=[version] CIX_OTHER_ARGS=[]
$ cbsd seance config --check                mode=[]        CIX_OTHER_ARGS=[config --check]
$ cbsd seance mode=config --check           mode=[config]  CIX_OTHER_ARGS=[--check]
$ cbsd seance repl --guest web01 --now      mode=[]        CIX_OTHER_ARGS=[repl --guest web01 --now]
$ cbsd seance mode=repl --guest web01 --now mode=[repl]    CIX_OTHER_ARGS=[--guest web01 --now]
$ cbsd seance verify --render cron          mode=[]        CIX_OTHER_ARGS=[verify --render cron]
$ cbsd seance mode=verify --render cron     mode=[verify]  CIX_OTHER_ARGS=[--render cron]
```

So a wrapper that reads `mode` **if set and `CIX_OTHER_ARGS` otherwise** loses
every flag of a `mode=`-spelled verb. seance's did, until this was run.
Measured with the dispatcher replaced by a script that prints its own argv,
against the same installed module, before and after:

```
                                       before the fix        after
$ cbsd seance config --check           argv=[config --check] argv=[config --check]
$ cbsd seance mode=config --check      argv=[config]         argv=[config --check]
$ cbsd seance mode=repl --guest web01 --now
                                       argv=[repl]           argv=[repl --guest web01 --now]
```

`cbsd seance mode=config --check` therefore used to print the configuration
dump and exit 0 where the operator had asked for a validation — no message, no
non-zero status, nothing anywhere saying the flag had gone nowhere. The wrapper
now passes **both**, in order:

```sh
exec ${_MYDIR}/bin/seance ${mode} ${CIX_OTHER_ARGS}
```

which makes the two spellings identical, as its ADDHELP now says. End to end on
the installed module, with the real dispatcher:

```
$ cbsd seance version           seance 0.1.0   $ cbsd seance mode=version        seance 0.1.0
$ cbsd seance config --check    PASS           $ cbsd seance mode=config --check PASS
$ cbsd seance --desc            Guest succession: replication, death detection, fencing, promotion
```

Pinned by `tests/tier1/t_verb_wrapper.sh`, which drives the wrapper under a
faked cbsdsh environment (the two sourced files replaced by empty ones,
`cixinit` defined as a function in the second, `bin/seance` replaced by a
script that prints its argv) — so the regression is caught on the workstation,
on every edit, without CBSD.

Note that `CIXARG` (required args) makes `cixinit` fail when the argument is
absent, so `mode` is a *CIXOPTARG*: `cbsd seance version` must not be a usage
error.

Verdict, end to end (`out/m0/04-verb-dispatch.txt`):

```
$ cbsd seance version           seance 0.0.0-m0      exit 0
$ cbsd seance mode=version      seance 0.0.0-m0      exit 0
$ cbsd seance help              usage: …             exit 0
$ cbsd seance bogus             unknown verb: bogus  exit 2
```

**`$0` is a symlink, twice over.** `${workdir}/modules/seance` points at
`${CIX_DISTDIR}/modules/seance.d/seance`, which on the spike host was itself
inside a symlinked directory. Any module that needs a file of its own must
resolve its real location; the idiom is
`modules/zfsinstall.d/zfsinstall:28`, and seance's wrapper uses
`_MYSELF=$( ${REALPATH_CMD} "$0" )`.

## 3. The environment a module sees

`cbsd.conf` is sourced before the verb runs and defines, among others:

| Variable | Value | Source |
| --- | --- | --- |
| `CIX_DISTDIR` | `/usr/local/cbsd` | `cbsd.conf:24` |
| `myversion` | `15.0.9` | `cbsd.conf:21` |
| `workdir` | from `$cbsd_workdir` in `/etc/rc.conf` | `cbsd.conf:28-36` |
| `etcdir` | `${workdir}/etc` | `cbsd.conf:73` |
| `dbdir` | `${workdir}/var/db` | `cbsd.conf:84,92` |
| `rundir` | `${workdir}/var/run` | `cbsd.conf:87` |
| `jailsysdir` | `${workdir}/jails-system` | `cbsd.conf:71` |
| `jaildatadir` | `${workdir}/jails-data` | `cbsd.conf:65` |
| `moduledir` | `${workdir}/modules` | `cbsd.conf:79` |
| `distmoduledir` | `${CIX_DISTDIR}/modules` | `cbsd.conf:81` |
| `nodenamefile` | `${workdir}/nodename` | `cbsd.conf:52` |
| `inventory` | `${workdir}/nc.inventory` | `cbsd.conf:53` |
| `subrdir`, `tools`, `system`, … | subroutine paths | `cbsd.conf:39-49` |

`nodename` is the node's identity, held in a one-line file:

```
$ cat /tank/state/cbsd/nodename
alpha
```
— `out/m0/02-initenv.txt`

seance's wrapper copies the ones it needs into `SEANCE_CBSD_*` and execs the
plain-sh dispatcher, so nothing below the wrapper runs under `cbsdsh`
(observed, `out/m0/04c-module-environment.txt`):

```
SEANCE_CBSD_DBDIR=/tank/state/cbsd/var/db
SEANCE_CBSD_DISTDIR=/usr/local/cbsd
SEANCE_CBSD_ETCDIR=/tank/state/cbsd/etc
SEANCE_CBSD_JAILDATADIR=/tank/state/cbsd/jails-data
SEANCE_CBSD_JAILSYSDIR=/tank/state/cbsd/jails-system
SEANCE_CBSD_NODENAME=alpha
SEANCE_CBSD_VERSION=15.0.9
SEANCE_CBSD_WORKDIR=/tank/state/cbsd
```

Also present: `CIX_APP` (the verb's own name), `CIX_PATH`, `CIX_PWD` (the
caller's working directory), `CIX_SHELL`, and the `*_CMD` tool-path macros
(`REALPATH_CMD`, `GREP_CMD`, …) that CBSD uses instead of hard-coded paths.

## 4. Configuration and state

**`readconf <file>`** (`subr/nc.subr:693-708`) sources, in order and where
readable:

1. `${etcdir}/defaults/<file>`
2. `${etcdir}/<file>`
3. `${moduledir}/${CBSDMODULE}.d/etc/<file>` — only when `CBSDMODULE` is set
4. `${jailsysdir}/${jname}/etc/<file>` — only when `jname` is set

It **sources**, so it is unusable for seance's config, which is parsed and
never sourced by spec (handoff §2.2). Path 2 is nevertheless where a
CBSD-idiomatic admin will expect the file, which is what D-3 chose.

Path 3 is a **defect**: `${moduledir}` is `${workdir}/modules`, which holds the
verb *symlinks* and nothing else — initenv never creates a `<module>.d/`
directory there. Observed:

```
$ ls -la /tank/state/cbsd/modules/seance.d
ls: /tank/state/cbsd/modules/seance.d: No such file or directory
```
— `out/m0/07-storage.txt`. So `readconf` layer 3 can never fire for a module
installed the documented way. Do not rely on it.

**CBSD gives a module no state directory.** `${workdir}/var/db` is where CBSD
keeps its own node state (`cbsd.conf:92`). The spike confirmed D-3's choice
directly: `${workdir}/etc`, `${workdir}/var/db` and `${workdir}/var/run` all
exist after initenv, root can create subdirectories and files in each, and both
the directories and their contents **survive a further `initenv`**, stage 9's
obsolete-file sweep included:

```
$ ls -ld …/etc …/var …/var/db …/var/run
drwxrwxr-x  3 cbsd cbsd  /tank/state/cbsd/etc
drwxrwx---  9 cbsd cbsd  /tank/state/cbsd/var
drwxrwx---  3 cbsd cbsd  /tank/state/cbsd/var/db
drwxrwxr-x  3 root cbsd  /tank/state/cbsd/var/run

… created …/var/db/seance/succession.log, …/var/run/seance/probe.lock,
  …/etc/seance.conf, then re-ran initenv …

$ cat /tank/state/cbsd/var/db/seance/succession.log
someguest	bravo	alpha	20260816T103500Z	fence:probe
$ cat /tank/state/cbsd/var/run/seance/probe.lock
probe
$ cat /tank/state/cbsd/etc/seance.conf
cadence=900
```
— `out/m0/07-storage.txt`. **D-3 is confirmed:** config at
`${workdir}/etc/seance.conf`, state at `${workdir}/var/db/seance/`, locks at
`${workdir}/var/run/seance/`.

## 5. SQLite helpers

`cbsdsqlro` (read-only) and `cbsdsqlrw` (read-write) are cbsdsh builtins (§2).
The first argument is a **database name**, not a path; it resolves against
`${dbdir}` by appending `.sqlite`. `local` is the node's own inventory, which
is itself a symlink named after the node:

```
$ cbsdsqlro local "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
bhyve
bhyveppt
…
carp
jails
…
storage_pools
vm_cpu_topology
…                                          rc=0

$ cbsdsqlro nodes "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
nodelist                                   rc=0

$ cbsdsqlro local "SELECT jname FROM jails"
                                           rc=0     (empty node)

$ cbsdsqlro nosuchdb "SELECT 1"
                                           rc=1

$ ls -la /tank/state/cbsd/var/db
… inv.alpha.sqlite
… local.sqlite -> inv.alpha.sqlite
… nodes.sqlite  authkey.sqlite  images.sqlite  storage_media.sqlite  vpnet.sqlite
```
— `out/m0/12-sqlite-helpers.txt`

Note the shape of the last two: **an unknown database returns rc 1 with no
output, and an empty table returns rc 0 with no output.** Empty output alone
does not distinguish success from failure — the crashed-verifier lesson,
present in CBSD's own interface. seance reads none of this directly (the seam
guard forbids it outside `lib/adapter.subr`); it is recorded because the
adapter's error handling has to be written against it.

## 6. Guests: enumeration, type, datasets, registration, lifecycle

Observed on an empty node (`out/m0/08-enumeration.txt`, `11-adapter-surface.txt`):

```
$ cbsd jls header=0                                   (no output)   exit 0
$ cbsd jls
JNAME  JID  IP4_ADDR  HOST_HOSTNAME  PATH  STATUS                   exit 0
$ cbsd jls header=0 display=jname,jid,path,ip4_addr,status
                                                      (no output)   exit 0
$ cbsd bls header=0                                   (no output)   exit 0
$ cbsd jorder                                         (blank line)  exit 0
$ cbsd jstatus jname=nosuchguest                      (no output)   exit 0
```

`cbsd jls --help` documents the contract the adapter will use: `display=` takes
a comma-separated column list (default
`jid,jname,ip4_addr,host_hostname,path,status`), `header=0` suppresses the
header, a bare argument list limits scope, and a trailing `WHERE …` is passed
to SQL — `cbsd jls ver=15.1 WHERE astart=1`.

**`cbsd jstatus jname=<absent>` exits 0 with no output — and the exit code IS
a reliable existence test, un-inverted correctly.** The MYDESC line says so
directly: "Return jail ID in output and jail existance as error code (0: no
jail, 1: jail exist)" (`jailctl/jstatus:5`). Without `invert`, `EXIST=1
NOT_EXIST=0` (`jailctl/jstatus:27-33`); the absent case observed live above is
exactly that default's `NOT_EXIST=0`. seance's adapter passes `invert=1`,
which swaps them to the ordinary sense — `EXIST=0 NOT_EXIST=1` — so under
`invert=1` a guest that does not exist here exits 1 with no output, and a
guest that does exits 0 and prints `${myjid}` on stdout
(`jailctl/jstatus:41-47`). `myjid` is computed against reality, not the
database, and by two different routes depending on guest type: for a jail,
`get_jid` walks `cbsdjls` for a matching name and sets `myjid` to the jid it
finds there, returning 1 (exists) or 0 (absent) (`subr/nc.subr:19-45`); for a
bhyve VM, by the existence of `/dev/vmm/<jname>` (`subr/rcconf.subr:117-127`).
This is what `adapter_guest_running` relies on (D-47; `lib/adapter.subr`,
`adapter_guest_running`): a non-zero jid means running, a jid of `0` means
present but stopped, and `invert=1`'s own `NOT_EXIST=1` means absent.

**The absent case is observed live, above. The exists case is UNVERIFIED live
until tier 5** — M0 had no guest to run it against, so everything above about
that branch is read from source, not watched happen. `tests/tier5/README`
names it as a required shape-B assertion: `cbsd jstatus jname=<n> invert=1`
for a guest that EXISTS must exit 0 and print its jid.

`cbsd version` prints the bare version once a workdir exists, and fails
loudly before that:

```
$ cbsd version            (no workdir yet)
cbsd: no workdir defined                       exit 1
$ cbsd version            (after initenv)
15.0.9                                         exit 0
```
— `out/cbsd-version.txt`, `out/m0/11-adapter-surface.txt`

Dataset conventions, from source only (**UNVERIFIED live** — creating a guest
was out of M0's scope): a jail's dataset is `<pool>/<jname>` mounted at
`${workdir}/jails-data/<jname>-data` (`sudoexec/mkdatadir:14-23`); a VM's is
`<pool>/<jname>` mounted at `${workdir}/vm/<jname>` with `jails-system` and
`jails-data` symlinks and zvols `<pool>/<jname>/dskN.vhd`
(`sudoexec/bcreate:573-600`, `sudoexec/zfs-recv:60-93`).

Making a replicated guest startable is `cbsd jregister jname=<n>
rcfile=${workdir}/jails-system/<n>/rc.conf_<n>` (`sudoexec/jregister:134-191`),
reversed by `cbsd junregister`. **UNVERIFIED live.**

## 7. Hook directories and their exit semantics (D-8)

`cbsd jcreate` creates thirteen per-guest hook directories under
`${jailsysdir}/<jname>/` (`sudoexec/jcreate:710-729`): `clone-local.d`,
`clone.d`, `create.d`, `facts.d`, `master_create.d`, `master_poststart.d`,
`master_poststop.d`, `master_prestart.d`, `master_prestop.d`, `remove.d`,
`rename.d`, `start.d`, `stop.d`. They live in `jails-system`, so they travel
with a replicated guest — which is what made `master_prestart.d` the preferred
boot-gate mechanism in D-8.

**A non-zero hook does not abort the start.** `sudoexec/jstart:665-669` and
`sudoexec/bstart:883-887` call `external_exec_master_script`
(`subr/jcreate.subr:166-215`) as a bare statement and never test its result.
Inside, each executable in the directory is run in the body of a
`find … | while read` pipeline (`:203-207`), and the function then restores
`PATH`, `CBSD_CWD` and `CIX_PWD` (`:209-214`) — so whatever the hook returned,
the function returns the status of the last `export`, which is 0. Reproduced
with the same construct and a hook that exits 7:

```
$ /tmp/hookfn.sh
Execute master script: failing_hook
hook ran
function returned: 0
jstart would now carry on and start the guest.
```
— `out/m0/09-hook-exit-semantics.txt`

**Consequence for D-8:** a `master_prestart.d` hook can *observe* and *notify*,
but it cannot *veto*. A boot gate that must actually prevent a start needs a
different lever — an rc.d unit ordered before CBSD's autostart that withholds
the estate, or a hook that removes the guest's registration/autostart flag
rather than returning non-zero. M2 chooses; M0's finding is that returning
non-zero is not a mechanism.

Status: the source path is read and the shell construct is reproduced live;
**a live `cbsd jstart` with a failing hook is UNVERIFIED** — it needs a real
jail with a base, which M0 did not build. The M2 stage that decides the boot
gate must run exactly that: create a minimal jail, drop an `exit 1` hook in
`${jailsysdir}/<jname>/master_prestart.d/`, `cbsd jstart`, and record whether
the jail comes up.

## 8. Known upstream defects (CBSD 15.0.9)

1. **`cbsd bregister` is a stub.** `bhyvectl/bregister` is two lines that
   source `new_sudoexec.subr`, which execs `${CIX_DISTDIR}/sudoexec/bregister`
   — a file the distribution does not ship:

   ```
   $ cbsd bregister --help
   /usr/local/cbsd/bhyvectl/bregister: 11: exec: /usr/local/cbsd/sudoexec/bregister: not found
   # exit: 127
   $ ls -la /usr/local/cbsd/sudoexec/bregister
   ls: /usr/local/cbsd/sudoexec/bregister: No such file or directory
   ```
   — `out/m0/11-adapter-surface.txt`. `sudoexec/bmigrate:358` still calls it.
   seance's adapter must use `jregister` for every guest type.

2. **`readconf`'s module layer can never fire** — path 3 is
   `${workdir}/modules/<module>.d/etc/`, which initenv never creates (§4).

3. **`cbsd module mode=install` cannot accept a manifest written the way every
   shipped module writes it.** `system/module:67` reads `MODULE_DIR` out of
   `metadata.conf` as *literal text* (grep + awk + sed, no expansion), so it
   holds the fourteen characters `${CIX_DISTDIR}` verbatim; `:78-82` then
   compares the first 23 characters of that literal against the *expanded*
   `"${CIX_DISTDIR}/modules"`. Asked of cbsdsh itself, with seance's own
   `metadata.conf` — which is byte-for-byte the shape of `pkg.d`'s:

   ```
   literal MODULE_DIR = [${CIX_DISTDIR}/modules/seance.d]
   first 23 chars     = [${CIX_DISTDIR}/modules/]
   compared against   = [/usr/local/cbsd/modules]
   RESULT: MISMATCH -- cbsd module mode=install would refuse this manifest
   ```
   — `out/m0/06-module-dir-prefix.txt`

   A manifest would have to hard-code `/usr/local/cbsd/modules/<name>.d` to get
   past the check, which no shipped module does. **UNVERIFIED end-to-end**: the
   spike could not run `mode=install` itself, because that path needs network
   and git and clones from `github.com/cbsd/modules-<name>`. This does not
   affect seance today — installation is `git clone` into place (D-1) — but it
   is the reason not to *depend* on `mode=install` for distribution.

4. **The module `ObsoleteFiles` mechanism looks in the wrong directory** — the
   same `moduledir`/`distmoduledir` confusion as defect 2. Stage 9 sources
   `${moduledir}/<name>.d/ObsoleteFiles` (`sudoexec/initenv:1411-1412`), i.e.
   `${workdir}/modules/<name>.d/ObsoleteFiles`, and `${workdir}/modules` holds
   only the verb symlinks — the file it wants is at
   `${CIX_DISTDIR}/modules/<name>.d/ObsoleteFiles`. Observed absent:
   `ls: /tank/state/cbsd/modules/seance.d: No such file or directory`
   (`out/m0/07-storage.txt`). The paths it would remove are also resolved
   against `${workdir}` (`:1420`), so even a correctly located list would name
   files that are not there. A module cannot currently retire a file through
   this mechanism.

5. **`cbsd module` refuses to run at all without git(1)**, including
   `mode=list`, which needs no network (`system/module:185-186`):

   ```
   $ cbsd module mode=list
   cbsd: no such git, please install first: pkg install -y devel/git
   # exit: 1
   ```
   — `out/m0/03a-module-list-needs-git.txt`

6. **`cbsd initenv` cannot be run unattended, and fails silently when you try.**
   Three forms, all observed (`out/m0/03b-initenv-non-interactive.txt`):

   - `cbsd initenv` — interactive. `sudoexec/initenv:45-48` sets `inter=0` only
     when the *first* argument is literally `inter=0`; `getyesno`
     (`subr/nc.subr:398-414`) loops until it reads an answer, so with stdin at
     EOF it never returns. Observed twice: ten minutes of `[yes(1) or no(0)]`
     and a 1 GB log. It also re-execs itself under `lockf(1)`, so killing the
     process you started does not stop the one writing.
   - `cbsd initenv inter=0` — **exits 0 having done nothing.** `ALWAYS_YES=1` is
     set only when a preseed file was supplied (`sudoexec/initenv:1489-1494`),
     so the confirmation at `:1534` (`getyesno … || exit 0`) receives return 3
     from `nc.subr:392-396` and initenv stops before stage 0. No output, no
     stage, exit 0.
   - `cbsd initenv inter=0 <preseed> key=value` — **prompts anyway.** The verb
     `cbsd initenv` is `tools/initenv`, ten lines: it sets `CBSD_SUDO=1`,
     captures `ARGS=$( . ${cbsdinit} )` and execs `sudoexec/initenv ${ARGS}`.
     With `CBSD_SUDO` set, `init()` echoes back only the `key=value` pairs it
     parsed, re-quoted as `key="value"` (`subr/nc.subr:362`). The preseed path
     is not a `key=value` and is dropped; `inter=0` arrives as the literal
     `inter="0"` and fails the string compare at `:45`. Confirmed by `ps` during
     such a run: `lockf … env INITCFG= CBSD_INITCFG_EXTRA= … initenv start` —
     `INITCFG` empty.

   What works, as root, and what the package's own post-install message says:

   ```
   /usr/local/cbsd/sudoexec/initenv inter=0 \
       /usr/local/cbsd/share/initenv.conf \
       workdir=/tank/state/cbsd nodename=alpha jail_interface=vtnet0 \
       ipfw_enable=0 default_vs=0
   ```

   Argument rules: `inter=0` first (`:45-48`), then a *readable file* becomes
   the preseed `INITCFG` (`:54-57`), and every remaining word is written to
   `CBSD_INITCFG_EXTRA` (`:63-74`); the preseed is sourced first and the extras
   on top (`:1197`, `:1493`), so trailing `key=value` arguments override the
   file. All nine stages ran and the node came up as `alpha`
   (`out/m0/02-initenv.txt`).

   For a **re-run** that must keep the existing answers — the case after
   enabling a module — a preseed is not needed if the two variables are set in
   the environment (`:50-52`, `nc.subr:392-396`):

   ```
   env NOINTER=1 ALWAYS_YES=1 /usr/local/cbsd/sudoexec/initenv
   ```

   Observed running all stages, including stage 8
   (`out/m0/03b-initenv-non-interactive.txt`).

## 9. Packaging and distribution

CBSD's own channel is `cbsd module mode=install <name>`, which clones
`https://github.com/cbsd/modules-<name>.git` into the `MODULE_DIR` its
`metadata.conf` declares (`system/module:41-43,117-131`), prints
`message.txt` if present (`:133-136`), and offers `mode=upgrade` (a
`git pull --ff-only`, `:100-113`) and `mode=list` (`:142-181`). `mode=install`
refuses to overwrite an existing non-empty directory (`:86-93`), and both
`install` and `upgrade` reset `PATH` around the git call so that CBSD's own
`modules` directory cannot shadow `git` (`:101-108`, `:118-125`).

For seance the practical route is `git clone` into
`/usr/local/cbsd/modules/seance.d` — which is why the repository root is the
module directory (D-1) — followed by the `modules.conf` line and an initenv
re-run. Both defects 3 and 5 above are reasons not to make
`cbsd module mode=install` the supported path.

Two smaller conventions worth keeping:

- **`ObsoleteFiles`** in the module root, listing paths under
  `modules/<name>.d/` that a previous version shipped. Stage 9 intends to
  source each enabled module's copy and delete what it names
  (`sudoexec/initenv:1403-1421`, specimen `modules/pkg.d/ObsoleteFiles`) — see
  defect 4: on 15.0.9 it looks in a directory that does not exist. Ship the
  file anyway; it costs nothing and the convention will outlive the bug.
- **`message.txt`**, printed once by `mode=install`. seance ships one telling
  the admin the two remaining steps, because nothing about enabling a module is
  automatic.

## 10. What M0 did not establish

- Live `jstart`/`bstart` behaviour with a failing `master_prestart.d` hook
  (§7). Source-only, plus a faithful reproduction of the shell construct.
- Anything requiring a real guest: `jregister`, `jstart`, `jstop`, dataset
  layout, `jstatus` against an existing guest, `cbsd emulator`. Tier 5 (shape
  B) is where these get proven, in M2.
- `cbsd module mode=install` end to end (needs network and a published
  `cbsd/modules-seance` repository).
- Whether `cixinit` differs from `init` in any way that matters beyond the
  variable names — the spike exercised `--help`, `--desc`, `key=value` parsing
  and `CIX_OTHER_ARGS`, and all four behaved as `init` does.
