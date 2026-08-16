# seance — implementation handoff brief

*For the implementing agent. Read `seance-design.md` (v0.2) and `TESTING.md`
first; this brief pins what those leave open, fences the first milestone, and
states the rules of engagement. Where this brief and the design doc disagree,
this brief is newer.*

## 0. Rules of engagement (binding, non-negotiable)

1. **Evidence before assertion.** Never assert CBSD behavior, FreeBSD
   behavior, or tool syntax from memory. Read the installed CBSD's actual
   source/docs (it is sh — read it), run the command, or mark the claim
   UNVERIFIED and stop. This project's design was paid for by exactly this
   failure mode; it does not get reintroduced by its own implementation.
2. **Enumerate the class, not the symptom.** A bug fixed once is a bug class
   to sweep for everywhere.
3. **Testing non-negotiables** from TESTING.md §0 apply to every commit:
   never weaken a check to route around a defect; every fix ships with the
   test that would have caught it; mutation-check every new assertion; the
   tier-7 oracle self-test is written before tier 7 itself.
4. **No tenant strings in framework code** — the lint guard (TESTING.md §4)
   is among the first tests written, and it gates every commit thereafter.
5. **Scope fences are hard.** Build the current milestone only. Do not
   scaffold ahead (no devd hooks, no fencing code, no TUI until their
   milestone). Half-built future features are debugging surface.
6. Versioning: git is the checksum. Tag releases; no un-tagged artifact
   leaves the repo for a fleet machine.

## 1. M0 — the scaffolding spike (do this first, alone)

Goal: a working `cbsd seance version` verb installed as a genuine CBSD
external module on a FreeBSD 15.1 host with CBSD 15.0.9 — plus a short
`docs/cbsd-module-notes.md` recording, from *observed* source and behavior:
how modules are laid out and discovered, how verbs register and dispatch, how
a module reads CBSD's workdir/node facts, what (if any) storage a module gets,
and how modules are packaged/distributed in the CBSD ecosystem. Every claim in
that file cites the file/line or command output it came from. The k8s and
vncterm modules are the reference specimens. M0 exits when the notes file
exists and the hello verb runs; the notes then bind M1's structure.

## 2. Pinned specifications

### 2.1 Snapshot name grammar (the wire protocol)

    @seance-<node>-<YYYYmmddTHHMMSSZ>

- Timestamp: UTC always, exactly 16 characters, strftime `%Y%m%dT%H%M%SZ`.
- **Node names may contain dashes** (tenant zero's do). Therefore: parse from
  the right — the final dash-delimited field of exactly 16 chars matching the
  timestamp pattern is the timestamp; everything between `seance-` and that
  final dash is the node name, verbatim. Reject (as foreign, ignore-not-error)
  any `@seance-*` name that does not parse.
- Comparison is string comparison (the format sorts); staleness is
  now-minus-parsed with a configurable clock-skew tolerance
  (`skew_tolerance`, default 120s).
- Tier-2 vectors cover: dashed node names, truncated timestamps, non-UTC-
  looking timestamps, foreign prefixes, a node name that itself ends in a
  16-digit-like token (pathological, must still parse right-to-left).

### 2.2 Config file grammar

- Flat text, one `key=value` per line; `#` comments; no quoting semantics
  beyond trailing-whitespace trim. **Parsed, never sourced** — parsing is
  what makes `config --check` and hostile-input testing possible.
- Keys: lowercase `[a-z0-9_]`. Per-node: `node_<name>_<key>` (e.g.
  `node_hyp2c_mgmt`, `node_hyp2c_fence_driver`, `node_hyp2c_fence_target`).
  Per-guest overrides: `guest_<name>_<key>` (e.g. `guest_webdb01_cadence`).
  Node/guest names in keys use `[a-z0-9]` only — a `names` key maps them to
  display names if they differ (avoids the dash problem in keys).
- Fleet defaults: `cadence` (seconds, default 900), `retention_recent`
  (default 4h), `retention_hourly` (default 48h), `ssh_port` (default 22 —
  22, not 2212; 2212 is tenant config), `ssh_user` (default root),
  `skew_tolerance`, `debounce` (default 45), `staleness_max` (default
  3×cadence), `notify_cmd`, `witness` (optional, N=2 only).
- **Distribution is administrative, never automatic** (decided): seance never
  writes config across nodes. `seance verify` diffs the file across the mesh
  and flags divergence LOUDLY (exit-code-affecting, not a footnote). That is
  the entire synchronization story.
- The example site file committed to the repo is **fictional** (nodes alpha/
  bravo/charlie or similar). Tenant-zero's real site file is never committed
  unless properly deidentified (decided).

### 2.7 Succession records and the resurrection gate

- `seance promote` appends, on the successor, one TSV record per guest to
  `<module-state>/succession.log`: guest, old_home, new_home, UTC ts,
  evidence (`fence:<driver>` | `force:<operator>`); and updates
  `<module-state>/placement` (current guest→home map, one line per guest
  this node currently hosts away from home).
- Boot gate: before any estate autostart, a returning node queries each
  *living* peer (`seance placement --remote` over the mesh) for claims on
  its guests. Any claim → do not start that guest, notify. **No peers
  reachable → start nothing, notify.** Failback closes the record.
- Exact state-dir location defers to M0's findings on module storage.

### 2.3 Adapter contract (I/O discipline)

- sh functions in `adapter.subr` (real) and `tests/mock-adapter.subr` (mock);
  one conformance suite runs against both.
- **stdout is data, stderr is diagnostics, exit code is verdict**: 0 success,
  1 operation failed, 2 usage/contract error. Callers must treat empty stdout
  with exit 0 as a contract violation for functions that promise output —
  the crashed-verifier lesson, encoded (tier 4 has a test row for it).
- List-returning functions emit one record per line, fields tab-separated,
  no headers, field order fixed by the contract comment above each function
  and by the conformance suite's vectors. No field may contain a tab; names
  are validated on the way in.
- The full function list and signatures: design doc §2. The mock imports the
  real parsers (snapshot grammar, config) — it may not reimplement them.

### 2.4 Fence driver contract

- A driver is an executable: `fence_<driver> <action> <target> [args…]`,
  actions `off` (power off and wait until verified off, bounded by
  `fence_timeout`, default 60s) and `status` (exit 0 = target is OFF,
  1 = target is ON, 2 = cannot determine).
- `off` exits 0 **only on verified off**. "Command accepted" is not "off".
- Ships: `fence_ipmi` (ipmitool lanplus; endpoint/user/passfile from per-node
  config; password never in argv or logs). Test harness ships `fence_jail`
  (stops a pseudo-node jail, verifies with jls). Driver selection and target
  are per-node config keys.

### 2.5 Notify contract

- `notify_cmd` from config is executed with the subject as `$1` and the body
  on stdin. Exit code logged, never fatal to the caller (a promotion must
  not die because mail did). Default if unset: syslog only, at LOG_CRIT for
  the notify rung. That is the whole notification feature at v1 — anything
  richer is the tenant's `notify_cmd`.

### 2.6 Transport prerequisites (documented, verified, not assumed)

- Node-to-node ssh, key-based, as `ssh_user` on `ssh_port`, full mesh.
- Rough time sync (NTP-grade) across nodes; staleness math carries
  `skew_tolerance` but is not a substitute for sync.
- `seance verify` checks both (mesh reachability matrix; pairwise clock delta
  via `date +%s` over ssh) and reports, per the PASS/WARN/FAIL idiom.

## 3. Repository shape (proposal — adjust to M0's findings where they bind)

    seance/
      seance                    # dispatcher (the module entry)
      lib/policy.subr           # pure functions; no cbsd, no zfs calls
      lib/adapter.subr          # ALL cbsd/host interaction
      lib/repl.subr             # layer 1 (zfs via thin wrappers here)
      lib/common.subr           # logging, RC-capture pattern, conf parser
      drivers/fence_ipmi
      etc/seance.conf.sample
      tests/                    # tiers 1-5 harnesses + vectors/ + mock adapter
      tests/cluster/            # shape A stage scripts (tier 6-7)
      docs/cbsd-module-notes.md # M0 output
      TESTING.md  DESIGN.md  HANDOFF.md  DRILLS.md  LICENSE  README.md
      .reaper.toml

- Style: `#!/bin/sh`, `set -u`, no bashisms, no pipefail reliance (the
  RC-capture pattern from common.subr wherever a pipeline's verdict matters),
  shellcheck-clean with any directive carrying a stated reason (a narrowing,
  per the rules).
- License: BSD-2-Clause, Copyright (c) 2026 Axonibyte Innovations, LLC
  (decided).

## 4. Milestone fences (what each may and may not contain)

- **M0**: scaffolding spike only (§1). No seance logic.
- **M1**: `repl` + `status` + `config`/`verify`; policy functions with tier
  1–2 suites (written alongside), tier 3 guards, tier 4 truth table for the
  *staleness/lineage* rungs only; conf parser + vectors. Runs single-node.
  NOT in M1: promote, fencing, CARP, devd, TUI, failback.
- **M2**: `promote` (manual) + `failback` + mock-adapter ladder complete +
  shape B conformance + tier 6 stages repl/interrupt/promote/failback.
  NOT in M2: `--auto`, fencing beyond the driver contract + fence_jail.
- **M3**: CARP verify rendering + devd hook + `--auto` on one heir; tier 6
  quorum/concurrency stages; tier 7 with oracle self-test first; rediscovery
  battery (TESTING.md §8) green before anything is armed on real hardware.
- **M4**: fence_ipmi against real iDRACs; fleet drill-fence.
- **M5**: TUI (`setup`), packaging per M0's notes, README with the scars.

## 5. Decided (2026-08-16, owner)

- **Repo**: `bitbucket.org:axonibyte/seance`, public from day 1. Git
  etiquette per the owner's user-level CLAUDE.md.
- **License**: BSD-2-Clause, `Copyright (c) 2026 Axonibyte Innovations, LLC`.
- **Environment**: development and reaper both run on the owner's FreeBSD
  desktop (Claude Code shells in from there; reaper dispatches to the
  Proxmox provider locally). No Linux compatibility concerns anywhere in the
  toolchain — the harness targets FreeBSD `/bin/sh`, full stop. M0 runs in a
  reaper `freebsd-15.1` session (`pkg install` CBSD there; sessions double
  as disposable discovery labs, not just test beds).
- **Config sync**: administrative distribution + loud `verify` diffs (§2.2).
  No automatic propagation, ever.
- **Quorum**: general formula `1 + reachable_others > N/2` (design doc §7).
  N=2 and even-N half-splits degrade to notify-only + `--force`; witness is
  documented as the even-N recommendation but NOT implemented at v1.
- **Notify**: syslog-only default; `notify_cmd` is the configuration point
  (§2.5). Nothing richer in v1.
- **Shape B CBSD pin**: version string pinned in the manifest run command;
  the suite records `cbsd version` in its output so drift is visible.
- **Tenant zero site facts** (live in AxB's infra repo, NOT in this repo
  except deidentified): succession ring 2c←2a, 2a←2b, 2b←2c; cadence
  defaults 15m with webdb01=5m, crowdeasedev01=60m, bbrunner01=60m,
  artifact01=15m accepting fat bulk deltas (no pause hook until it hurts).

## 6. Questions the agent must NOT resolve by assumption

Ask, or leave marked, never guess: anything CBSD-internal not covered by
M0's notes; module state-dir location before M0 answers it; any deviation
from a pinned spec in §2, which requires editing this brief first, not
silently diverging from it. When a needed fact is missing from the design
doc, TESTING.md, this brief, and M0's notes — that is a question for the
owner, not an invitation to improvise.

## 7. Model selection per stage

Verified against Anthropic's model docs 2026-08-16 (platform.claude.com/docs
→ models overview); re-check at each milestone boundary — the lineup moved
twice this summer. Switch in Claude Code per task (`/model`); the rule is
**spend intelligence where a wrong answer is expensive and volume is low.**

| Work | Model | Why |
| --- | --- | --- |
| M0 scaffolding spike | Opus 5 | Reading unfamiliar sh source and resisting assumption is judgment work; volume is small |
| M1 repl engine + policy functions + tiers 1–4 | Opus 5 | Correctness-critical core; the tests are being born alongside the code they must outlive |
| M1–M3 mechanical batches (vector files from pinned specs, table-driven test expansion, shellcheck cleanup, doc formatting) | Sonnet 5 | Spec-following at volume; the spec, not the model, carries the correctness |
| M2 promotion ladder + failback implementation | Opus 5 | The split-brain-critical path |
| M2/M3 pre-merge review of ladder, failback, quorum, and every invariant/oracle | **Fable 5** | Highest-stakes reasoning at lowest volume — the exact Fable profile; a missed hole here is the one expense worse than its price |
| M3 tier-7 design: simulated-cluster generator, shadow model, shrinker, oracle self-tests | Fable 5 to design, Opus 5 to implement | Property-based oracle design is the subtlest thinking in the project |
| M4 fence_ipmi + real-iDRAC integration | Opus 5 | Small, careful, hardware-adjacent |
| M5 TUI, packaging, README | Sonnet 5 | Mechanical; escalate the README's design-rationale sections to Opus 5 |
| Trivial batch chores (rename sweeps, comment fixes) | Haiku 4.5 | Only when the diff is reviewable at a glance |

Fallback if Fable 5 is unavailable on the plan in use: Opus 5 at maximum
effort for the review rows, and say so in the PR. Never downshift models to
Sonnet/Haiku for anything touching the promotion ladder, quorum, fencing, or
an invariant — price is the wrong axis there.
