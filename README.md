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

## Status: M0 — scaffolding spike

The module scaffold, the test harness, and the tier-3 guards exist. **No seance
logic exists yet.** The only verb is `version`.

What is here:

| Path | What it is |
| --- | --- |
| `metadata.conf`, `securecmd`, `message.txt` | CBSD module markers |
| `seance` | the CBSD verb, a `cbsdsh` wrapper that execs `bin/seance` |
| `bin/seance` | the dispatcher, plain `/bin/sh` |
| `lib/common.subr` | logging, exit discipline, RC capture, temp dirs |
| `tools/lint.sh` | `sh -n`, `shellcheck`, tiers 1–4 |
| `tests/` | the harness and the tier directories |
| `docs/cbsd-module-notes.md` | what M0 learned about CBSD, with citations |

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

## License

BSD-2-Clause. Copyright (c) 2026 Axonibyte Innovations, LLC.
