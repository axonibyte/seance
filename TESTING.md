# seance testing specification

*Companion to `seance-design.md` §15. Adopts the reaper project's
`docs/testing-methodology.md` — the portfolio-of-oracles framing and all §2
non-negotiables — and maps each tier onto seance. Written before any seance
code exists, deliberately: the oracle self-tests come first.*

## 0. Non-negotiables (inherited verbatim, restated as binding)

Never weaken a test, check, assertion or lint to route around a defect — no
skips, exclusions, threshold-lowering, `|| true`, or scope-narrowing without a
stated reason covering exactly what it narrows. Every fix ships with a test
that would have caught it, or an explicit statement of why none can exist.
Pre-existing failures are proven pre-existing before being blamed. Every new
assertion is mutation-checked: break the thing, watch the test fail — a test
never observed failing has unmeasured value. Fix causes, not symptoms.

And the methodology's own acceptance test, which seance is unusually equipped
to pass: **the defect catalog already exists.** The August 2026 migration
produced real failures with known mechanisms; the harness must rediscover
them when their protections are reverted (§8 below).

## 1. Where tests run

Workstation — the owner's FreeBSD desktop, where Claude Code and reaper both
run (fast loop): tiers 1–4 — pure sh, no ZFS, no jails, milliseconds; the
harness targets FreeBSD `/bin/sh` and nothing else.
reaper session, guest `freebsd-15.1` (template 9004): tiers 5–7 — the guest is
byte-parity with tenant zero's fleet (15.1-p2, releng/15.1-n283596), carries
proven vnet jails, loadable CARP, and full OpenZFS. Fleet: tier 8, the drills
(design doc §10) — real hardware, real iDRAC, real deaths; never simulated
away.

Session shapes:

**Shape A — pseudo-cluster** (tiers 6–7): three vnet jails as nodes on an
internal bridge, each running seance with a delegated dataset subtree under
`tank/state/seance/<node>`, real ssh between jails, real CARP vhids, and the
`jailfence` fence driver whose "power off" is stopping the target jail (real
fence *semantics*: it verifies the node stopped answering). The adapter is
mocked at guest lifecycle only — guests are records, not processes — because
everything the policy engine and replication engine actually touch (datasets,
snapshots, sends, CARP state, ssh, fencing) is real.

**Shape B — adapter truth** (tier 5): single node, real CBSD (version-pinned
`pkg install` in the run command), one real minimal jail guest driven through
the real adapter: list, type, datasets, register, start, probe, stop. This is
where "the adapter's model of CBSD matches CBSD" gets proven, and it is the
tier that breaks first when CBSD changes an invocation convention again.

Substrate rules (from the template's own documentation): test datasets under
`tank/state` are children the runner's guards do not cover — every suite
creates and destroys its own, trap-based, with `reset` as backstop only;
manifest requests 4 cores / 8 GiB for shape A; long hunts renew their TTL.

## 2. Tier 1 — pure unit (workstation)

The policy functions, kept deliberately out of the verbs so they are testable
without a system: snapshot-name parse/format/compare; staleness arithmetic
(boundaries: exactly-at-threshold, threshold-plus-one-second, clock skew
within tolerance); succession resolution (heir, second heir, per-guest
override, absent entries); quorum evaluation as a pure function of
(cluster size N, count of reachable others) implementing
`1 + reachable > N/2` — boundary cases are the point: N=3 one-dead (act),
N=4 one-dead (act), N=4 clean half-split (freeze), N=2 peer-dead (freeze —
always, v1 has no witness), reach-nobody (freeze), N=1 degenerate (reject at
config validation, not here); retention-ladder selection (which snapshots
survive a prune at each age boundary). Table-driven, `sh` test harness, no
ZFS anywhere.

## 3. Tier 2 — golden vectors (workstation)

The snapshot name is the wire protocol, and two independent implementations
consume it: the repl writer (formats) and the promote/status parsers (parse).
Neither is the oracle; a committed vector file is — names with expected parses
(including hostile ones: wrong prefixes, truncated timestamps, a node name
containing a dash, a name from a foreign tool). Config parsing gets the same
treatment: one committed config corpus, expected effective values.

Run the vectors twice, reaper-style hostile-environment refinement: once
normally, once under `LC_ALL=C` vs a UTF-8 locale and under `TZ` set to a
non-UTC zone — because timestamps are UTC-always by spec, and the suite must
fail if an implementation accidentally localizes.

## 4. Tier 3 — source-as-data (workstation)

The rot-catchers, cheapest tier per defect:

- **Seam guard**: nothing outside `adapter.subr` invokes `cbsd`, `jls`,
  `bhyvectl`, or reads CBSD's sqlite. Grep-based, deliberately dumb.
- **Tenant guard** (the decoupling contract's teeth): no site strings — node
  names, site IPs, ports-as-literals, hardware serials — anywhere in module
  code. The forbidden list lives in the test, not in code comments.
- **Config completeness**: every key in `seance.conf.sample` is read
  somewhere in code; every `conf_get` key in code appears in the sample.
- **Verb completeness**: every verb in the dispatcher has a section in the
  man page / README, and vice versa.
- **Doc liveness**: every command the README shows exists verbatim in the
  dispatcher (the "control named in copy must exist" rule, applied to a CLI).

## 5. Tier 4 — policy vs fault-injecting mock adapter (workstation)

The fake-API tier, aimed at infrastructure: the full promotion ladder driven
against a scripted mock adapter that can return, per call, any of: success,
failure, timeout, garbage output, and — the crashed-verifier lesson encoded
as a test class — *empty output with success status*. Every rung × every
outcome has an expected disposition (proceed / abort / notify / force-only),
asserted as a truth table. The mock imports the real parsers (snapshot-name,
config) rather than reimplementing them, so it cannot drift into testing
itself. This is also where `--force` semantics are pinned: force skips
exactly the rungs it names, no more. And one row for the notify contract:
`notify_cmd` failing (missing, crashing, hanging past its timeout) never
changes a rung's disposition — a promotion must not die because mail did.

## 6. Tier 5 — adapter conformance (reaper, shape B)

One conformance suite, run against both the mock (tier 4's) and the real CBSD
adapter, asserting identical contracts: same fields, same error shapes, same
exit-code discipline. The real side drives an actual jail through its
lifecycle. When CBSD 15.x+1 changes something, this tier names it before the
fleet meets it.

## 7. Tiers 6–7 — pseudo-cluster: staged integration, then simulated cluster life (reaper, shape A)

**Tier 6, staged** (named stages, individually runnable, reaper-style):
`repl` (lineage established A→B and A→C, lag reported, retention prunes both
ends, `-x mountpoint -x canmount -u` verified by inspecting received
properties — the shadow-mount law asserted, not assumed); `interrupt`
(kill -9 a send mid-stream; next tick resumes via token, lineage intact);
`promote` (stop node-jail A via fence driver; B walks the ladder; assert
mounts, registration calls, per-guest RPO report); `quorum` (isolate a jail
with the bridge instead of stopping it; the isolated node must do nothing,
the connected heir must fence first); `concurrency` (trigger promotion on two
heirs simultaneously; **exactly one** acts — asserted from cluster state
afterwards, not from exit codes, per the count-the-resource-not-the-responses
rule); `failback` (return A; reverse incrementals; home again; normal
direction resumes); `resurrection` (the boot gate, both halves: fence A and
promote its estate to B, then start jail A *without* failback — A must query
peers, learn of B's claim, start none of its estate, and notify; then
isolate a fresh returning node from all peers — reaching nobody, it must
start nothing and notify. Only after `failback` closes the record may A's
autostarts proceed); `hostile` (foreign snapshots in the tree, a replica with
a *newer* timestamp than its source [clock skew], a dataset someone mounted
by hand).

**Tier 7, simulated cluster life** — the seeded tier, smallest useful
version first: a generator dealing weighted events from a fixed seed (tick
replication; kill a node; isolate a node; flap a link; prune during send;
double-trigger a promotion; return a dead node; skew a clock) against a
**shadow model** of expected placement and lineage, with invariants diffed
continuously:

1. **No guest is ever active on two nodes** (the split-brain invariant — the
   reason seance exists);
2. every promotion was preceded by a confirmed fence or a recorded human
   force;
3. lineage is monotonic — no replica ever regresses;
4. no data-bearing dataset is ever destroyed by seance;
5. the cheap oracle on every action: every verb exits with a verdict, no
   verb hangs, logs parse.

Determinism reaper-style: seed printed on every run, replayable by env var,
fixed committed seed set as the default battery, hunting runs opt-in, **any
seed that ever finds a defect is promoted into the fixed set permanently.**
On failure: shrink by prefix-bisection, then by event-kind removal.

**The oracle self-test comes first** — before tier 7 runs against real
seance, the invariants are fed hand-built broken states (a two-node-active
placement; a promotion log with no fence record; a regressed replica) and
each must complain. An invariant that never fires is indistinguishable from a
passing suite; this is the check that makes the expensive tier mean anything,
and it runs in under a second with no cluster at all.

## 8. Tier 8 — fleet drills (design doc §10) and the rediscovery battery

Drills stay on real hardware as milestone gates. Separately, the
methodology's acceptance test, run once the harness stands: **revert each
protection and confirm rediscovery** —

| Reverted protection | The harness must produce |
| --- | --- |
| receive without `-x mountpoint` | tier 6 `repl` stage fails on received properties; tier 7 invariant 4-adjacent (a shadow mount over live data) |
| promotion without fencing | tier 6 `quorum`/tier 7 invariant 2, and invariant 1 under the isolation event |
| verifier that masks its own crash (`2>/dev/null` on empty output) | tier 4's empty-output-with-success row flips a rung's disposition |
| stale-lineage promotion without threshold | tier 6 `hostile` stage |
| quorum rule removed | tier 6 `concurrency`: two actors |
| boot gate removed (returning node autostarts its estate) | tier 6 `resurrection` stage; tier 7 invariant 1 under the return-a-dead-node event |

A methodology that cannot rediscover the August defects is not yet measuring
anything — and we know their mechanisms by heart, which is the one asset the
month left us that no greenfield project gets.

## 9. Manifest sketch (`.reaper.toml`, seance repo root)

    schema = 1
    project = "seance"
    guests = ["freebsd-15.1"]
    exec = "host"

    [build]
    cmd = "sh tools/lint.sh"          # shellcheck if present, sh -n always,
                                      # tiers 1-4 (they are cheap enough to
                                      # run as 'build')
    [run]
    cmd = "sh tests/run.sh"           # tier 5 (shape B stages) + tiers 6-7
                                      # (shape A stages); stage selection via
                                      # env, reaper profiles for the long
                                      # hunts
    [sync]
    exclude = ["/out/"]

    [reset]
    datasets = ["state"]

    [resources]
    cores = 4
    ram_gb = 8

*(Shape A vs B is stage selection inside one session, not two guests: the
pseudo-cluster and the real-CBSD single node coexist under tank/state without
conflict, and one session per loop keeps the concurrency cap breathable.)*

## 10. Order of construction

Per the methodology's return-on-effort ordering, adjusted for what seance is:
tier 1 units alongside the first policy functions; the tier 7 **oracle
self-test before tier 7 itself**; tier 4's truth table before the ladder is
trusted; tier 3 guards the day the repo goes public-shaped; shapes A/B as M1
and M2 land (the design doc's milestones each name their gating stages); the
rediscovery battery before M3 arms any automation.
