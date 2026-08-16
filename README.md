# seance

**A CBSD module for guest succession: replication, death detection, fencing,
and promotion.**

When a node in a bhyve/jail cluster dies, its guests come back on a survivor in
minutes — automatically where that is provably safe, and manually everywhere
else. seance is pure FreeBSD `/bin/sh`, installs as a CBSD external module, and
carries no site knowledge in its code: everything site-shaped lives in a config
file that is not in this repository.

Design rationale is in `DESIGN.md`; the testing contract is in `TESTING.md`;
the implementation brief is in `HANDOFF.md`.

## Status: M2 — manual promotion, failback, the boot gate

Layer 1 is live: `repl` snapshots, sends and prunes; `status` is the one screen;
`verify` renders the configuration seance expects and diffs it against reality.
On top of it, the succession ladder: `promote` walks it by hand, `failback`
runs it in reverse, `gate` withholds a returning node's estate until the living
have been asked, and `placement` is the record they answer from.

CARP detection, `--auto` and the shipped `drivers/fence_ipmi` driver are later
milestones and are deliberately absent: M2 ships the fence-driver *contract*
and drives it with test drivers only.

What is here:

| Path | What it is |
| --- | --- |
| `metadata.conf`, `securecmd`, `message.txt` | CBSD module markers |
| `seance` | the CBSD verb, a `cbsdsh` wrapper that execs `bin/seance` |
| `bin/seance` | the dispatcher, plain `/bin/sh` |
| `lib/common.subr` | logging, exit discipline, RC capture, temp dirs |
| `lib/policy.subr` | the policy engine: snapshot names, UTC time arithmetic, staleness, quorum, succession, retention, lineage — pure functions, no clock but one injectable "now" |
| `lib/conf.subr` | the configuration file, parsed and never sourced |
| `lib/adapter.subr` | every fact about CBSD and the host, behind one seam |
| `lib/transport.subr` | ssh to peers, and a timeout around anything |
| `lib/notify.subr` | `notify_cmd`, bounded and never fatal |
| `lib/zfs.subr` | every local `zfs` invocation seance makes, in one file |
| `lib/lineage.subr` | what this node holds for another, and whether it may be promoted |
| `lib/repl.subr` | layer 1: snapshot, resume, send, hold the shadow-mount law, prune both ends, record lag |
| `lib/promote.subr` | the seven-rung succession ladder |
| `lib/failback.subr` | the ladder in reverse, plus the interim host's `failback-assist` half |
| `lib/gate.subr` | placement records and the resurrection gate |
| `lib/status.subr`, `lib/verify.subr` | the two reporting verbs |
| `rc.d/seance_gate` | runs the gate before CBSD's autostart |
| `etc/seance.conf.sample` | every key, documented, with its default |
| `tools/lint.sh` | `sh -n`, `shellcheck`, tiers 1–4 |
| `tests/` | the harness, the tier directories, and the committed vectors |
| `tests/tier4/ladder.tsv` | the promotion ladder's truth table: every rung × every outcome |
| `tests/drivers/fence_mock` | a fence driver that produces every answer the contract names, including the three that are not answers |
| `docs/cbsd-module-notes.md` | what M0 learned about CBSD, with citations |
| `docs/repl-wire.md` | the exact send/receive command lines, and the evidence for each |
| `docs/DRILLS.md` | the fleet drills each milestone is gated on |
| `docs/RUNBOOK-failback.md` | what to do, in order, when a node comes back |

The configuration file is `$SEANCE_CONF` if set, otherwise
`$SEANCE_CBSD_WORKDIR/etc/seance.conf` — which is `~cbsd/etc/seance.conf` on a
node running under CBSD.

## Verbs

Every verb the dispatcher answers to has a section here, and every section
names a verb the dispatcher answers to. `tests/tier3/t_verb_docs.sh` asserts
both directions against the source, so a verb added without a section — or a
section left behind after a verb was removed — fails the suite.

### seance repl

One replication tick, and the target of the crontab line `verify` renders. Per
guest, per peer: one atomic recursive snapshot, any interrupted receive
finished from the peer's resume token, an incremental send from the newest
snapshot the two ends have in common, the shadow-mount law held on every
replica dataset, both ends pruned by the same retention ladder, and a lag
record written for `status` to read.

```sh
seance repl                        # a tick; each guest is skipped unless its
                                   #   own cadence has elapsed
seance repl --now                  # tick regardless of cadence
seance repl --guest web01          # one guest
seance repl --peer bravo           # one peer
seance repl --dry-run              # say what would be sent where; touch nothing
```

Peers are the guest's succession — its heir and second heir, or the per-guest
override. Each pair runs under `lockf(1)`, so a tick that finds a pair already
running logs it and moves on rather than overlapping.

Each tick also mirrors what the guests' own datasets do not carry. A jail's
registerable configuration lives in `${jailsysdir}/<n>/`, outside the guest's
dataset, so `repl` copies it into one extra dataset per node —
`<pool-of-jails-data>/seance-sys`, mounted at `<state-dir>/sys` — and
replicates that dataset like a guest, to the same heirs. Without it a survivor
would hold a jail's data and have no way to register it. A VM needs none of
this: the platform already symlinks its configuration into its dataset.

Verdict line:

```
repl: 2 guests x 3 pairs, 3 ok, 0 failed, 0 skipped, 0 in progress
```

Exit 0 when every pair attempted succeeded, 1 when any failed, 2 on a
configuration or contract error. `--locked` is internal: it is how the tick
re-enters itself under the lock, and it does exactly one pair without taking a
snapshot.

### seance status

The one screen. Per guest: type, home, whether it is running here, whether it
is held, and the freshness of its replica on every peer. Then the mesh: each
peer's kernel version and the checksum of its configuration file.

```sh
seance status
seance status --tsv                # the same facts, one record per line
```

Replica freshness comes from the lag records this node wrote, never from the
peers — a `status` that asked a dead node about its own replicas would hang
exactly when it was needed. Kernel version and configuration checksum do cross
the mesh, because both are questions about the living, and every probe is
bounded by a timeout.

Exit 0 when every replica is fresh and the mesh agrees, 1 on any warning (a
stale replica, an unreachable peer, a kernel mismatch, a configuration that
differs), 2 when the configuration is invalid or this node is not in it.

### seance verify

Render the configuration seance expects, and diff it against reality:
`config --check`, the mesh reachability matrix, the pairwise clock delta, one
configuration file across the whole mesh, this node's standby parents on every
peer, and the crontab line.

```sh
seance verify
seance verify --render cron        # print the expected crontab(5) line
seance verify --render cron > /usr/local/etc/cron.d/seance
```

**`verify` never writes anything** — not the crontab, not a ZFS property, not a
configuration file. It prints what it expects and where reality differs,
because a verifier that repairs is a verifier whose green run says nothing
about the state it was asked to check. Exit 0 when everything PASSes, 1 when
anything WARNs or FAILs, 2 when the configuration could not be validated.

### seance promote

The succession ladder, for a node that has died. Seven rungs, every one of them
logged as `rung <n> <name>: <verdict> — <reason>`, every one of them able to
stop the whole thing, and one verdict line at the end.

```sh
seance promote alpha                       # walk the ladder for alpha's estate
seance promote alpha --guest web01         # one guest of it
seance promote alpha --force=fence         # accept a fence that could not confirm
seance promote alpha --force=quorum,lineage
seance promote alpha --force               # every forceable rung
```

| Rung | What it asks | What stops it |
| --- | --- | --- |
| 1 debounce | is the trigger still true? | M2 is manual, so `n/a`; the CARP re-check hangs off this rung at M3 |
| 2 quorum | `1 + reachable_others > N/2`? | a freeze is `notify`, and `--force=quorum` is the documented N=2 / even-N escape |
| 3 probes | does the dead node answer ping or ssh? | **any** answer aborts, and no `--force` can reach this rung |
| 4 fence | did the driver verify it off? | refused/still-on aborts and pages; cannot-determine notifies |
| 5 lineage | per guest: whose is it, does anybody already claim it, is the replica fresh, is the fleet kernel-homogeneous? | a stale replica is `force-only`; no replica at all aborts |
| 6 promotion | mount in place, relink, register, start, verify, record | a guest that will not start fails alone; the others continue |
| 7 post | what the next `repl` tick will do | nothing; there is nothing to configure |

**`--force` names rungs, and skips exactly the ones it names** — every rung it
overrides says `forced` in its own line. The forceable rungs are `quorum`,
`fence`, `lineage` and `kernel`. `--force=probes` is a usage error: a host that
answers is never fenced by force. And `--force=fence` does **not** skip the
fencing — a configured driver is run every time, and one that reports *refused
or still on* aborts whatever was typed. What the force overrides is *cannot
determine*: no driver, no driver installed, an unreachable endpoint, a timeout,
or a success with nothing to say.

Promotion is **in place**: the replica stays where replication put it, under
`<standby_root>/<dead>/<guest>`, and is given the mountpoint the platform
expects. A guest whose configuration did not travel inside its own datasets — a
jail — has it restored from the dead node's configuration mirror, which is
mounted read-only for the copy and put back afterwards; a guest whose
configuration did travel is registered straight from the replica. Every mutating step prints its undo. Each guest reports its RPO — the
age of the newest replica snapshot at the moment it was promoted, which is
exactly what the promotion cost.

Exit `0` when the estate was promoted or correctly stood down, `1` when the
ladder stopped, `2` on a usage or configuration error.

### seance failback

Bring a guest home. Run it **on the guest's home node**, after that node is back
and gated, and while the guest is held or stopped there.

```sh
seance failback web01
seance failback web01 --discard-origin-writes
```

The interim host stops the guest, takes a final snapshot, and the origin pulls
the reverse incremental into its **live** dataset with `zfs recv -F`. That
rolls the origin back to the incremental base — so before it happens seance
measures `written@<base>` on every dataset and **refuses, printing the byte
count**, unless `--discard-origin-writes` says the operator has looked at those
bytes and decided they are debris. The decision is recorded in the succession
record as `discard:<bytes>`.

Exit `0` when the guest is home and running, `1` when the failback stopped, `2`
on a usage or configuration error.

### seance failback-assist

**Internal.** The interim host's half of a failback, invoked over the mesh by
the origin. It is documented because the operator finishing a half-failed
failback by hand needs it, not because anything else should call it.

```sh
seance failback-assist web01 stop         # stop it here
seance failback-assist web01 start        # put it back, if a failback was refused
seance failback-assist web01 snapshot     # final @seance-<self>-<now>
seance failback-assist web01 unregister   # unregister, unmount, mountpoint=none
seance failback-assist web01 release      # drop the claim, close the record
```

These are also the undo lines `seance promote` prints beside the steps it
cannot otherwise reverse.

### seance gate

The resurrection gate (`rc.d/seance_gate` runs it before CBSD's autostart). For
every guest whose home is this node, it asks each **living** peer whether that
peer already claims it. Any claim withholds that guest. **No peer answering at
all withholds the whole estate** — a node that can reach nobody must assume it
is the isolated one.

```sh
seance gate                     # withhold what must be withheld
seance gate --check             # say what it would withhold; change nothing
seance gate --release web01     # release one guest, if no peer still claims it
```

A guest is withheld by putting it in the platform's slave mode, which survives
a reboot because it is in the platform's own database. `seance failback`
releases it; so does `--release`, which refuses while a peer still claims the
guest or while no peer answers.

Exit `0` when nothing is withheld, `1` when anything is, `2` on a usage or
configuration error.

### seance placement

Which guests this node is hosting **away from home** — the claim the gate and
the ladder read.

```sh
seance placement            # this node's claims
seance placement --remote   # the same, gathered from every living peer
```

Records are `placement<TAB><guest><TAB><home>` locally, and
`placement<TAB><peer><TAB><guest><TAB><home>` with `--remote`, then a verdict
line. The local form deliberately needs no adapter: it is what every peer runs
over ssh to answer "are you holding one of mine", and a node whose platform is
not up must still be able to answer.

**A peer that cannot answer is named, not skipped.** `--remote` exits `1` and
says which living peers could not report, because an unanswered peer is not a
peer with no claim — and everything that reads these records treats it that
way: the gate withholds the whole estate, `promote` aborts, `failback`
refuses. If you see it, `ssh <peer> seance placement` is the diagnosis.

**Mesh prerequisite:** `seance placement` must be runnable as `ssh_user` on
every node — a link to `bin/seance` somewhere on that user's `PATH`. CBSD's own
`PATH` belongs to `cbsdsh`, not to an ssh session.

### seance config

Print the effective configuration (fleet defaults, then per-node and per-guest
values), then a verdict line. With `--check`, print one `problem:` line per
fault and nothing else. `--file <path>` overrides which file is read.

```sh
seance config            # the effective configuration, then a verdict line
seance config --check    # one line per problem; exit 0 valid, 1 invalid,
                         #   2 the file could not be parsed
seance config --file /path/to/seance.conf --check
```

Exit codes: `0` the configuration is valid, `1` it loaded and is invalid, `2`
it could not be found or could not be parsed.

### seance version

Print `seance <version>`, from the `VERSION` file beside the module. Exit `1`
if that file is missing or empty — a version seance cannot state is not a
version it may guess.

```sh
seance version
```

### seance help

Print the usage summary: the verbs, where the configuration file is looked
for, and what the exit codes mean. `seance --help` and `seance -h` are the
same verb.

```sh
seance help
seance --help
```

## Running the tests

On a FreeBSD workstation, tiers 1–4 (pure sh, milliseconds):

```sh
sh tools/lint.sh          # sh -n + shellcheck + tiers 1-4
sh tests/run.sh           # tiers 1-4 alone
SEANCE_TIERS=3 sh tests/run.sh    # one tier
```

`tools/lint.sh` says loudly when `shellcheck` is absent and skips that phase
rather than pretending to have run it.

Tiers 5–7 need root, ZFS and jails, and run in a [reaper](../../../tech/code/util/reaper)
session against the `freebsd-15.1` guest:

```sh
reaper up
reaper test               # sync -> build (lint) -> reset -> run (tiers 5-7)
reaper down
```

The run's first act is `tests/lib/guest-prologue.sh`, which installs CBSD and
fails the suite if the version is not the pinned `cbsd-15.0.9`.

Tier 6 is a set of named stages; one at a time:

```sh
SEANCE_TIERS=6 SEANCE_STAGES=repl sh tests/run.sh
```

And the harness's own acceptance test — revert each protection this project has
already paid for once, and require the suite to rediscover it. Run before a
milestone is trusted, never automatically:

```sh
sh tests/rediscovery/run.sh --tier 4      # workstation, seconds per row
sh tests/rediscovery/run.sh --tier 6      # reaper session, minutes per row
```

The tier-4 rows are the cheap half — promotion without fencing, stale-lineage
promotion without a threshold, and the boot gate removed all have to fail a
workstation test before they are allowed to fail a cluster one.

## Installing as a CBSD module

The repository root *is* the module directory, so a clone into place is a
complete installation:

```sh
git clone <this repo> /usr/local/cbsd/modules/seance.d
echo seance.d >> ~cbsd/etc/modules.conf
cbsd initenv                       # stage 8 links the verb; answer yes
cbsd seance version
```

Stage 8 symlinks `${CIX_DISTDIR}/modules/seance.d/seance` to
`${workdir}/modules/seance` and records `mod_seance_enabled=YES` in
`${workdir}/nc.inventory`. Removing the line from `modules.conf` and re-running
the initialisation undoes both.

If you are automating this, do **not** use `cbsd initenv inter=0`: it exits 0
having done nothing, and a bare `cbsd initenv` without a terminal never returns.
The unattended form is

```sh
env NOINTER=1 ALWAYS_YES=1 /usr/local/cbsd/sudoexec/initenv
```

`docs/cbsd-module-notes.md` has the citations, the observed output, and the
other CBSD 15.0.9 defects worth knowing before relying on any of this.

### Two steps the clone does not do for you

**The boot gate.** `rc.d/seance_gate` has to be installed where rc(8) reads
units, and enabled — it is disabled by default, because a unit that began
withholding guests the moment the module landed would be a surprise:

```sh
cp rc.d/seance_gate /usr/local/etc/rc.d/seance_gate
sysrc seance_gate_enable=YES
service seance_gate onestart          # try it now, before you rely on a reboot
```

It is ordered `BEFORE: cbsdd`, which is the only ordering that gets in front of
the estate coming up: the autostart is not an rc(8) unit of its own, it is
started from inside that daemon's prestart.

**`seance` on the mesh's PATH.** One node runs `seance placement` on another
over ssh, and an ssh session gets the login PATH rather than any shell's, so
the module's dispatcher needs a link somewhere that PATH covers:

```sh
ln -s /usr/local/cbsd/modules/seance.d/bin/seance /usr/local/bin/seance
ssh <peer> seance placement           # the test that it worked
```

Without it, every peer reads as silent — and a gate that hears silence from
every peer withholds the whole estate, which is correct behaviour arriving for
the wrong reason.

## Exit codes

`0` ok, `1` operation failed, `2` usage or contract error. stdout is data,
stderr is diagnostics, and every verb that *acts* on the fleet — `repl`,
`status`, `verify`, `config` — ends in a verdict line. `version` and `help`
are data-only: they print the version and the usage summary and nothing else,
which is what makes `seance version` usable inside a shell substitution.

## Documents

| Document | What it is |
| --- | --- |
| `DESIGN.md` | design rationale |
| `TESTING.md` | the testing contract, tier by tier |
| `HANDOFF.md` | the implementation brief |
| `docs/cbsd-module-notes.md` | what M0 learned about CBSD 15.0.9, with citations |
| `docs/repl-wire.md` | the exact `zfs send`/`recv` command lines, and the evidence for each |
| `docs/DRILLS.md` | the fleet drills each milestone is gated on |
| `docs/RUNBOOK-failback.md` | the failback runbook, and what each refusal means |

## License

BSD-2-Clause. Copyright (c) 2026 Axonibyte Innovations, LLC.
