# Tier 7 — simulated cluster life: design (binding for the implementer)

*Written by the orchestrator (handoff §7: Fable 5 designs, Opus 5 implements).
Lives at `tests/cluster/sim/DESIGN.md` from M3 on. TESTING.md §7 is the
specification; this document is the mechanism. Where they disagree,
TESTING.md wins and this file is wrong.*

## 0. What this tier is for

Tiers 1–6 prove seance against fixtures somebody imagined. Tier 7 lets a
seeded generator imagine them, for hundreds of steps, against a *shadow
model* of what must be true, and diffs continuously. Its unique question:
**what breaks only after history accumulates** — a promotion that lands on a
node still holding a stale hold from an earlier event, a prune that removes
the base of a send that started before the prune, two heirs triggered while
a failback is half done.

The oracle is cheap and general on purpose (methodology §9/§11): the five
invariants of TESTING.md §7 plus the per-action cheap oracle. Correctness of
placement *choices* is asserted only where the design makes it a hard rule.

## 1. Architecture (six parts, TESTING.md §7 / methodology §11)

```
tests/cluster/sim/
  DESIGN.md              this file
  seeds.txt              committed fixed seed set (default battery)
  gen.subr               seeded PRNG + weighted event chooser
  world.subr             the *real* world driver: applies an event to the
                         pseudo-cluster (cluster.subr) and to seance
  model.subr             the shadow model: partial truth, updated per event
  invariants.subr        the checker: model vs observed cluster
  oracle.subr            cheap oracles applied to EVERY seance invocation
  shrink.subr            prefix bisection, then event-kind removal
  run.sh                 the driver: seed -> event trace -> verdict
tests/tier4/t_sim_oracle_selftest.sh
                         tier 4 cost, no cluster: broken states -> must fire
tests/tier1/t_sim_gen.sh
tests/tier1/t_sim_shrink.sh
                         the generator's and the shrinker's own unit tests
tests/tier7/t_sim.sh     the tier entry (fixed seeds; hunting opt-in)
```

*(The self-test was written to `tests/tier4/` rather than to this directory,
per D-56: `tests/run.sh` collects `t_*.sh` from `tests/tier<N>/` only, and the
whole point of a self-test that needs no cluster is that it runs on the
workstation on every `sh tools/lint.sh` rather than once per reaper session.
`tests/tier7/t_sim.sh` still runs it first and refuses to spend a session if
it does not pass. `tests/cluster/sim/` holds only sourced `.subr` files, the
seeds and this document.)*

## 2. Determinism

- PRNG: a 32-bit LCG or xorshift in pure sh integer arithmetic
  (`$(( ))` is 64-bit on FreeBSD sh; mask to 32 bits). Seed printed on every
  run as the first line: `# seed <n>`; replayable via `SEANCE_SEED=<n>`.
- Everything that must vary between runs but not between replays (the
  cluster instance tag, temp dirs) is drawn *outside* the seeded stream.
- The event trace is written as it happens to `$REAPER_OUT/sim/<seed>.trace`
  (one line per event: `<step> <kind> <args>`), so a failing run's trace is
  data even if the process dies.
- Wall-clock is not part of the model: seance's `pol_now` is injectable via
  `SEANCE_NOW` (an epoch the driver advances by a "virtual tick" per event);
  the driver sets it for every seance invocation so replication cadence and
  staleness are functions of the trace, not of the guest's speed. (`repl`
  reads `SEANCE_NOW` when set; production never sets it.)

  *(As built in M3, per D-120: `pol_now` is the single place, so every verb
  gets the hook and none of them has one of its own. A `SEANCE_NOW` that is set
  and is NOT a non-negative epoch is a CONTRACT ERROR -- rc 2, no output -- and
  never a quiet fall back to the real clock, because a seeded run that silently
  used wall time is a run the shrinker would then spend hours bisecting for
  nothing. The world driver must therefore treat a failed `pol_now` as its own
  bug. Pinned by `tests/tier1/t_policy_now.sh`, including that an exported value
  reaches a child process -- which `repl`'s per-pair re-execution under
  `lockf(1)` (D-62) depends on.)*

## 3. Actors and world

- Nodes: `alpha bravo charlie` (N=3) by default; a profile for N=4 (adds
  `delta`) exists because the even-N freeze must be exercised.
- Guests: 4–6 fictional guests, homes dealt from the seed, ring succession
  from the sample config, one guest with a per-guest heir override.
- The world driver applies events with the substrate (`cluster_*`) and with
  seance verbs run inside node jails via `cluster_exec`.

## 4. Event vocabulary and weights (the nemesis is not a mode)

| kind | weight | what the world does |
|---|---|---|
| `tick` | 40 | advance `SEANCE_NOW` by one cadence; run `seance repl` on every live, non-isolated node |
| `kill` | 8 | pick a live node; `cluster_stop` (== power loss); the fence driver will find it stopped |
| `isolate` | 6 | pick a live node; `cluster_isolate` (alive, unreachable) |
| `heal` | 6 | pick an isolated node; `cluster_heal` |
| `flap` | 4 | isolate then heal within the same event, no tick between (transient master) |
| `promote` | 10 | pick a dead/isolated node D and an heir H; run `seance promote D --auto` on H (M3) — the ladder decides |
| `double-trigger` | 5 | run `seance promote D --auto` on BOTH heirs concurrently (`&` + wait) |
| `return` | 6 | pick a dead node; `cluster_start` — its boot gate runs (rc.d ordering simulated by running `seance gate` before anything else on that node) |
| `failback` | 5 | pick a guest away from home whose home is live; run `seance failback` for it |
| `prune-during-send` | 3 | start a `repl` on a fat guest in the background and, before it finishes, run a second `repl` (which must skip on lock) and a manual retention prune |
| `skew` | 3 | shift one node's `SEANCE_NOW` by ±(skew_tolerance+60) for the next 3 events, then restore |
| `hostile-snap` | 2 | create a foreign snapshot (`@zrepl-…`, or a `@seance-<node>-<bad ts>`) on a live node's replica or source |
| `hand-mount` | 2 | mount a replica dataset by hand on a peer (`zfs set canmount=on mountpoint=/mnt/x` … then the next repl must repair or refuse — see invariant 4a) |

Weights are a table in `gen.subr`; the generator draws only from events
*currently applicable* (no `heal` with nothing isolated, no `failback` with
nothing away). Applicability is computed from the **model**, not the world.

## 5. Shadow model (deliberately partial)

Per node: `alive|dead|isolated`, `held` guests (slave mode), current
`SEANCE_NOW` offset. Per guest: `home`, `placement` (node currently
authorised to run it — exactly one, or none while dead and unpromoted),
`lineage`: for each (guest, node) the newest `@seance-*` ts the model
believes exists, and the last promotion's evidence (`fence:<driver>` |
`force:<who>` | none). Per event the model applies the *rules*, not the
implementation: e.g. after `promote D --auto` on H the model expects
placement to move **only if** quorum(N, reachable) == act AND the fence
verified off AND lineage fresh; otherwise placement is unchanged and a
notify is expected. The model does not predict lag values or exact snapshot
names — it predicts *monotonicity* and *uniqueness*.

*(As built, per D-134: the model predicts the node roster, each guest's home and
a LOWER BOUND on lineage — after a tick, the node hosting a guest has taken a
local `zfs snapshot -r`, which cannot fail to exist without seance having lied
about the tick. It does NOT predict that a send arrived (a send crosses the
network the nemesis is cutting, and predicting it would fire invariant 3 every
time the nemesis worked), and it does not predict where a promotion lands:
`invariants.subr` as built reads no such expectation — invariant 2 asks the
RECORDS whether a move carried evidence — and a "prediction" copied from the
observation it is checked against is worse than no prediction, because it looks
like one. Placement, holds and post-fence liveness are therefore READ BACK after
each event, and the file says so where it does it. What survives from this
section is the part with teeth: applicability is computed from the model and
never from the world. The model also offers an ISOLATED node as a promote
actor, because that is what CARP does to a node that hears nobody — without it
this tier would never exercise the quorum rule at all.)*

## 6. Invariants (checked after every event and at the end)

1. **No guest is active on two nodes** — observed: for every guest, count
   nodes where the pseudo adapter says `running=1`; must be ≤ 1. Also ≤ 1
   node with placement in `placement` files (`SEANCE_STATE_DIR/placement`
   across nodes) unless one of them is `held`.
2. **Every promotion has evidence** — every line appended to any node's
   `succession.log` carries `fence:<driver>` or `force:<operator>`; a
   promotion observed (placement changed) without a matching record is a
   failure; and the model's expected outcome (act/notify/abort) matches
   the ladder's verdict line for that invocation.
3. **Lineage is monotonic** — for every (guest, node) the newest
   `@seance-*` ts never decreases across events (observed via
   `zfs list -t snapshot`), and the model's newest ≤ observed newest.
4. **No data-bearing dataset destroyed by seance** — the set of guest root
   datasets and their children (excluding snapshots) never shrinks unless
   the event was an explicit destructive test action (there are none in v1);
   4a: no replica ever has `canmount=on` or a real `mountpoint` set by
   seance — after `hand-mount`, the next `repl` must either restore
   (`canmount=noauto mountpoint=none`) and log it, or refuse that pair with
   a FAIL line; either is coherent, silent acceptance is not.

   *(As built, per D-136 and resolving D-112: the world driver emits `props`
   rows for the copies under `<standby_root>/<home>/<guest>` and not for the
   copy on the guest's own home. The home's copy is the original — it carries
   the mountpoint the platform gave it and always will — so a state that
   offered it would fire 4a on every correct post-promotion cluster, which is
   how an invariant comes to be switched off. What stops a returning home from
   STARTING it is the boot gate, which is invariant 1's business and which the
   `return` event exercises directly.)*
5. **Cheap oracle on every action** (`oracle.subr` wraps every seance call):
   exit code ∈ {0,1,2}, a verdict line present as the last stdout line
   matching `^[a-z]+: `, wall time under `SEANCE_SIM_STEP_TIMEOUT` (never
   hangs), stderr parses (no `set -u` "parameter not set", no `command not
   found`, no sh syntax errors), logs under `SEANCE_STATE_DIR` parse.

   *(As built: the verdict regex is `ORACLE_VERDICT_RE` in `oracle.subr`, not
   `^[a-z]+: ` — no verb seance ships satisfies that, `config` ending in
   `PASS`/`FAIL: …` and `version` in `seance <v>`, so pinning it would make
   this invariant fire on every correct run. See D-55 for the grammar actually
   pinned and the stderr pattern list. The "logs parse" clause is implemented
   in invariant 2's clause A, where the records are: it is a property of a
   state, not of an invocation.)*

## 7. Oracle self-test (written FIRST, `tests/tier4/t_sim_oracle_selftest.sh`, tier-4 cost)

Feed `invariants.subr` hand-built *observed* states + model states with no
cluster at all (the checker takes its observations through injectable
functions: `obs_running <guest>`, `obs_snapshots <node> <ds>`, `obs_records
<node>`, `obs_props <node> <ds>`; the self-test substitutes fixtures):

*(As built, every observation function takes the state directory as its first
argument — `obs_running <state> <guest>` — per D-57: invariants 3 and 4 are
transition invariants over two observed states, and without the argument the
checker would have to mutate a global between two calls to the same function.
The second narrowing argument is the guest rather than a dataset name, because
a replica's dataset name is not stable across nodes and the guest is. The
exact file formats both states use are the `# format:` blocks at the top of
`invariants.subr`, which are the contract the world driver implements.)*

- two nodes running `web01` → invariant 1 fires;
- a succession record with neither `fence:` nor `force:` → 2 fires; a
  placement change with no record → 2 fires;
- a (guest,node) newest ts that goes backwards between two states → 3 fires;
- a dataset present in state k, absent in k+1 → 4 fires; a replica with
  `canmount=on` after a tick → 4a fires;
- an invocation whose last line is not a verdict / rc 3 / stderr containing
  `parameter not set` → 5 fires;
- and the negative control: a coherent pair of states → nothing fires.

Each invariant must be seen firing before tier 7 is allowed to run against
the real cluster; `t_sim.sh` runs the self-test first and refuses to
proceed if it does not pass (an oracle that cannot fire is not an oracle).

## 8. Shrinking

On the first failing seed: (1) prefix bisection — rerun the same seed with
`SEANCE_SIM_STEPS=k` for k halving down until the failure disappears, keep
the shortest failing k; (2) event-kind removal — for each kind in the trace,
rerun with `SEANCE_SIM_SKIP=<kind>` (the generator draws as before but skips
that kind, keeping the stream aligned), keep the removal if it still fails.
Print the reduced trace. State plainly that reruns land on a fresh cluster
(rebuilt per run) so a non-reproduction is a weak signal.

*(As built, per D-58: (1) is a true binary search rather than halving down —
the same number of reruns for a same-or-shorter answer, and reruns are the
expensive thing; it assumes the failure is monotone in prefix length and says
so in its output when the assumption does not hold. `SEANCE_SIM_SKIP` is a
comma-separated list, because removals accumulate. The kinds tried in (2) are
the kinds in the reduced prefix, not in the whole trace. And the shrinker
reproduces the unreduced failure before it bisects: a shrinker that skips that
step reports a confident one-step "minimal" trace for a run that was never
failing.)*

## 9. Battery and hunting

`seeds.txt` starts with 5 seeds (chosen once, committed); default battery =
those seeds × `SEANCE_SIM_STEPS=60`; wall budget ≈ 5 × (60 × ~3 s) ≈ 15 min
inside the guest (the `repl` tick dominates; keep guests tiny). Hunting:
`reaper run --profile hunt` (TTL 6h) with `SEANCE_HUNT=1` draws seeds from
`/dev/urandom` (printed) for as long as the budget allows. **Any seed that
ever finds a defect is appended to `seeds.txt` permanently**, with the
commit that fixed the defect referenced in a comment.

*(As built, per D-137: `t_sim.sh` REPORTS a failing seed to
`$REAPER_OUT/sim/seeds-to-promote.txt` and does not edit `seeds.txt` itself.
This same runner is what the rediscovery battery drives with a protection
deliberately reverted (§10), and a runner that appended on every failure would
fill the permanent battery with seeds that found a hole somebody made on
purpose. `SEANCE_SIM_SEEDS` replaces the battery with a named list — announced
in the output, so a run that used it cannot be read as the battery — which is
how a tier-7 rediscovery row costs one cluster rebuild rather than five. And
`SEANCE_SIM_DRY=1` (D-135) draws and models a trace with no cluster at all,
which is how the generator and the applicability rules are exercised on a
workstation.)*

## 10. Rediscovery hooks (TESTING.md §8)

The M3 rediscovery battery runs the fixed seeds against reverted
protections: quorum removed → invariant 1 under `double-trigger`/`isolate`;
fencing removed → invariant 2; boot gate removed → invariant 1 under
`return`; recv without `-x mountpoint` → invariant 4a under `hand-mount`.

*(As built, and measured rather than predicted: three of the four rows
rediscover — fencing removed, quorum removed and the boot gate removed, each
against seed 2950315648 for 27 steps, a window chosen by reading its trace
(D-143). The fourth does NOT and has been removed: seance re-holds the
shadow-mount law on every tick (D-65), so a receive without `-x mountpoint` has
been repaired before the driver observes any property and invariant 4a has
nothing to see. That revert is caught by the tier-6 `repl` row, which asserts
that a clean tick repairs nothing. A row that cannot fail reads as coverage of
a protection nothing is checking, which is worse than no row (D-125).)*
