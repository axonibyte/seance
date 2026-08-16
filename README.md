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

## Status: M1 — replication, status, verify

Layer 1 is live: `repl` snapshots, sends and prunes; `status` is the one screen;
`verify` renders the configuration seance expects and diffs it against reality.
Promotion, fencing, CARP and the boot gate are later milestones and are
deliberately absent.

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
| `lib/zfs.subr` | every local `zfs` invocation seance makes, in one file |
| `lib/repl.subr` | layer 1: snapshot, resume, send, hold the shadow-mount law, prune both ends, record lag |
| `lib/status.subr`, `lib/verify.subr` | the two reporting verbs |
| `etc/seance.conf.sample` | every key, documented, with its default |
| `tools/lint.sh` | `sh -n`, `shellcheck`, tiers 1–4 |
| `tests/` | the harness, the tier directories, and the committed vectors |
| `docs/cbsd-module-notes.md` | what M0 learned about CBSD, with citations |
| `docs/repl-wire.md` | the exact send/receive command lines, and the evidence for each |
| `docs/DRILLS.md` | the fleet drills each milestone is gated on |

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
running logs it and moves on rather than overlapping. Verdict line:

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

### seance config

```sh
seance config            # the effective configuration, then a verdict line
seance config --check    # one line per problem; exit 0 valid, 1 invalid,
                         #   2 the file could not be parsed
seance config --file /path/to/seance.conf --check
```

### seance version

```sh
seance version
```

### seance help

```sh
seance help
seance --help
```


### seance config

Print the effective configuration (fleet defaults, then per-node and per-guest
values), then a verdict line. With `--check`, print one `problem:` line per
fault and nothing else. `--file <path>` overrides which file is read.

Exit codes: `0` the configuration is valid, `1` it loaded and is invalid, `2`
it could not be found or could not be parsed.

### seance version

Print `seance <version>`, from the `VERSION` file beside the module. Exit `1`
if that file is missing or empty — a version seance cannot state is not a
version it may guess.

### seance help

Print the usage summary: the verbs, where the configuration file is looked
for, and what the exit codes mean. `seance --help` and `seance -h` are the
same verb.

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
already paid for once, and require the suite to rediscover it. Minutes per row,
run before a milestone is trusted, never automatically:

```sh
sh tests/rediscovery/run.sh --tier 6
```

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

## Exit codes

`0` ok, `1` operation failed, `2` usage or contract error. stdout is data,
stderr is diagnostics, and every verb ends in a verdict line.

## Documents

| Document | What it is |
| --- | --- |
| `DESIGN.md` | design rationale |
| `TESTING.md` | the testing contract, tier by tier |
| `HANDOFF.md` | the implementation brief |
| `docs/cbsd-module-notes.md` | what M0 learned about CBSD 15.0.9, with citations |
| `docs/repl-wire.md` | the exact `zfs send`/`recv` command lines, and the evidence for each |
| `docs/DRILLS.md` | the fleet drills each milestone is gated on |

## License

BSD-2-Clause. Copyright (c) 2026 Axonibyte Innovations, LLC.
