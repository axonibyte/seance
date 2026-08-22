# seance

**A CBSD module for guest succession: replication, death detection, fencing, and promotion.**

*Design document v0.2 — 2026-08-16. Status: FOR TEARDOWN. No code exists; nothing here is settled until it survives review. Open decisions are marked ⟡. v0.2 adds: the decoupling/open-source contract (§14), configuration UX (§15), and the reaper-hosted testing strategy (§16 + TESTING.md), following review of the reaper framework and the proven freebsd-15.1 guest template.*

*Naming: the project and module are `seance` — the mechanism literally raises a dead node's guests to run through a living host. ("vigil" is reserved for a future security product and is not used anywhere in this project.)*

---

## 1. Purpose and non-goals

seance gives tenant zero's three-node bhyve/jail cluster what GlusterFS promised and never delivered: when a node dies, its guests come back on a survivor in minutes, automatically where that is provably safe and manually everywhere else. It is built tenant-first and site-specific, but designed for extraction: the CBSD-facing surface is isolated behind an adapter so the module can eventually ship through CBSD's external-module ecosystem (`cbsd seance <verb>`) without a rewrite.

Non-goals, stated so they stay dead: no shared storage of any kind (the gluster lesson is load-bearing); no live migration (planned evacuation uses CBSD's own tooling); no synchronous replication (this is crash-consistent, minutes-stale failover, not zero-RPO HA); no support for hypervisors other than bhyve and no container runtimes other than CBSD jails; no rewriting of host network configuration (seance verifies CARP, it does not own it).

## 2. Architecture: the seam

Two components, one hard boundary:

**The adapter** (`adapter.subr`) owns every fact about CBSD and the host platform: enumerating guests and their types, reading guest configs, starting and stopping guests, node identity, dataset paths, and the version-specific invocation quirks this campaign paid for (bare guest names, `env workdir=` on initenv, verb prefixes). It exposes a small stable interface and nothing else calls CBSD, ever. When CBSD changes an argument convention again, one file changes.

**The policy engine** (`policy.subr` + the verb entry points) owns every decision: what constitutes death, quorum, the fencing ladder, succession order, promotion sequencing, failback. It reasons about abstract guests with names, types, homes, and heirs. It is deliberately ignorant of bhyve, jails, tmux, and sqlite, and could in principle drive a different backend through a different adapter — which is the extraction story.

Adapter interface (the contract, first cut — teardown target):

    node_self                       -> nodename
    node_peers                      -> list of (nodename, mgmt_ip, bmc_ip)
    guest_list [node]               -> list of (name, type, home_node, ram, autostart)
    guest_type <name>               -> bhyve | jail
    guest_start <name>              -> rc            # dispatches bstart/jstart by type
    guest_stop <name>               -> rc            # bstop/jstop, ACPI-graceful where possible
    guest_running <name>            -> boolean       # pgrep bhyve / jls, by type
    guest_datasets <name>           -> list of datasets under <pool>/cbsd
    guest_register <name> <node>    -> rc            # make guest startable here (pre-registration model)
    kernel_version                  -> freebsd-version -k   # homogeneity precondition
    carp_state <vhid>               -> MASTER | BACKUP | absent

Everything in seance is sh (`set -u`, shellcheck-clean, self-logging, checksummed releases) — tool for the job: it must live in CBSD's sh ecosystem, run with zero build dependencies, and be readable by an adrenaline-soaked admin at 03:00, a bar this week made vivid.

## 3. Guest model

Guests carry a `type` (bhyve today; jail supported in the contract from day one, drilled when one exists). Layer 1 is type-blind — datasets are datasets. Promotion is type-aware only inside the adapter's dispatch. Two jail-specific preconditions live in `status` as checks rather than assumptions: kernel homogeneity across nodes (jails run the host's kernel — fleet doctrine already enforces this, seance verifies it), and network mode (vnet jails promote like VMs, MACs traveling in replicated config; IP-alias jails get their alias applied by the normal start path).

## 4. Layer 1 — replication (`seance repl`)

Bespoke, in-module, sh. ⟡ *Decision made in discussion (bespoke over zrepl) — confirm at teardown.* The engine per tick, per guest, per peer: snapshot the guest's dataset tree atomically (`zfs snapshot -r`), incremental send from the last peer-acknowledged snapshot to the peer's `<pool>/standby/<home>-cbsd/...`, prune both ends per retention, record lag. Non-negotiables encoded from history: every receive is `-u -x mountpoint -x canmount` (the shadow-mount law); standby parents stay `canmount=noauto, mountpoint=none` forever; a per-guest-per-peer lockfile so runs never overlap; resumable sends via `-s` and receive tokens so a fat interrupted delta continues instead of restarting.

**Snapshot naming is the wire protocol** (per the state-model principle, a survivor must determine lineage and staleness from names alone):

    @seance-<homenode>-<YYYYmmddTHHMMSSZ>

UTC always. The newest common `@seance-*` snapshot between a replica and its source defines the incremental base; the newest replica snapshot's timestamp *is* the staleness. No database, no queries to the possibly-dead.

Cadence and retention are per-guest config with a fleet default: ⟡ default 15 min; proposed overrides db01=5 min, dev01=60 min; build01 gets a `pause`/`resume` hook (or an accepted fat delta) around poudriere bulks. Retention: keep all of the last 4 hours, hourly to 48 hours, then gone — pruned identically on source and replica. Crash-consistency is the stated model (a promoted db01 boots as from power loss; InnoDB replays); a pre-snapshot hook point exists per guest for future quiesce ceremony, unused at v1.

`seance repl` runs from cron (the module installs the crontab line); it is not a daemon. Lag surfaces in `status` and trips a warning threshold (default: 3 missed intervals).

## 5. State model (calcified)

The promotion decision consumes only locally observable facts (CARP transitions, ping/ssh probes, fence-driver responses, local dataset state) plus already-replicated data (guest configs in `jails-system`, snapshot names) plus the local seance config — which is **distributed by the administrator, never propagated by seance**; `verify` diffs it across nodes and flags divergence loudly (automatic config propagation is a footgun when the file names fence credentials). Nothing may require asking the node presumed dead; asking *living* peers (the resurrection gate, §8) is permitted. Any state seance keeps beyond snapshot names — succession records, placement — lives in flat files under its module directory, per-node.

## 6. Succession

The map is explicit config, not discovery — pre-agreed inheritance so exactly one survivor acts per failure:

    # guest-or-node -> heir -> second heir
    alpha:   charlie bravo   ⟡ proposed ring: charlie←alpha, alpha←bravo, bravo←charlie
    bravo:   alpha charlie   #   alternative: bravo←alpha (keeps two heavy estates on
    charlie: bravo alpha     #   separate survivors post-failover) — CHOOSE AT TEARDOWN

Memory math holds in all arrangements (worst estate: alpha's 64G onto a 128G survivor). The ring proposal puts 2a's estate — the likeliest to move, given the suspect RAID controller — on charlie, the drilled pilot. Per-guest heir overrides are supported but discouraged (whole-estate moves keep the mental model simple).

CARP: three vhids, one per node identity, advskew encoding the map (owner 0, heir 100, second heir 200). The vhid IPs are heartbeat tokens only — guests keep their own MACs and DHCP identities wherever they run. seance *prescribes* the CARP config (`seance verify` renders the expected rc.conf lines and diffs reality) but never writes host network config. Known caveat from this week, stated in verify's output: bridge-MAC behavior on 15 is settled via the site firewall's DHCP reservations; CARP vhid MACs are derived from vhid numbers and are stable by construction.

## 7. Detection and the decision tree (`seance promote`)

devd matches a CARP MASTER transition on a vhid this node is heir to, and fires `seance promote <deadnode> --auto`. The engine then walks the ladder — every rung logged, every rung abortable:

1. **Debounce**: wait 45 s; re-verify this node still holds MASTER for the vhid (flapping links produce transient masters).
2. **Quorum**: a node may act only if `1 + reachable_other_nodes > N/2` — count yourself, strict majority of the configured cluster. N=3, one dead: 2>1.5, the survivor pair acts. Even N handles single-node death fine (N=4, one dead: 3>2) but freezes on a clean half-split (2-2: nobody acts) — automation stops at notify and a human resolves it; that freeze is correct fail-safe behavior, sacrificing availability, never consistency. The recommendation for even-N sites (including N=2, where quorum is unformable the moment the peer dies) is a witness/tiebreaker making the voting population odd — documented, not implemented at v1: N=2 and half-split even-N degrade to notify-only + `--force`. A node that can reach nobody must assume *it* is the isolated one and does nothing, loudly.
3. **Independent death probes**: ping and ssh the dead node's management IP. Any response aborts automation (CARP said dead, host says alive → investigate, don't promote).
4. **Fencing — the split-brain answer.** Detection cannot distinguish dead from isolated; two writers on diverging datasets is the one outcome worse than an outage. The promoting node invokes the configured **fence driver** against the corpse — the shipped driver is `ipmi` (`ipmitool -I lanplus chassis power off`, then verify `power status` reads off; iDRAC/BMC endpoints and credentials come from site config), but the contract is any command that powers off a named node and verifies it (Redfish, a managed PDU, or — in the test harness — stopping a jail). One driver ships; the door is open a crack for others; no plugin ABI. Three rungs:
   - **Fence confirmed** → automation proceeds. Split-brain is now impossible, not merely unlikely.
   - **iDRAC unreachable** (consistent with total power loss — but not proof) → automation stops at **notify**. A human, having looked at the facility, runs `seance promote <node> --force` which records the human decision and proceeds.
   - **Fence refused / power reads on** → hard abort, page loudly. Something is deeply wrong.
5. **Promotion proper**, per guest in the dead node's estate, in configured order: verify replica lineage (newest `@seance-<dead>-*` present and within staleness bounds — stale beyond threshold requires `--force`); clone-or-promote decision is *neither* — the replica datasets get explicit per-guest `mountpoint=` set (parents stay `none`, the ceremony from the shadow-mount era), mounted, guest registered via adapter, started via type dispatch; report per-guest RPO (snapshot age) in the completion summary.
6. **Post-promotion**: replication for the promoted guests reverses direction toward the remaining peer; the dead node's return is a failback event, never an automatic reclaim.

`--auto` is the devd path and requires rungs 1–4 green. Bare `seance promote <node>` (human-invoked) runs the same ladder interactively. `--force` skips exactly the rungs it names in its output, and writes who/when/why to the log.

## 8. Failback (`seance failback`) — manual, forever

Promotion writes an append-only **succession record** on the successor (guest, old home, new home, UTC timestamp, fence evidence or operator identity for a `--force`). The resurrection gate reads it from the other side: when the dead node returns (repaired, rolled back, rebuilt — or simply powered back on by a well-meaning human after being fenced), its boot-time seance check asks its *living peers* who is home for its estate before any autostart — asking the living is permitted; the prohibition was ever asking the dead — and if a successor claims a guest, or if **no peers answer at all**, it starts nothing and notifies. Fail-safe in every direction.

Failback itself: quiesce the promoted guest on the interim host, final reverse incremental (`@seance-<interim>-*` lineage) back to the origin, flip mounts and registration, close out the succession record, start at home, resume normal replication direction, prune the interim lineage. Every step is the promotion machinery run in reverse by the same code paths — one implementation, two directions.

## 9. Verbs

    seance status          # the one screen: every guest — home, running-where,
                           #   replica freshness per peer, CARP states, kernel
                           #   homogeneity, config drift. Exit code = fleet health.
    seance repl            # one replication tick (cron target); --guest, --peer filters
    seance verify          # render expected CARP/devd/cron config, diff against reality
    seance promote <node>  # the ladder; --auto (devd), --force (human override)
    seance failback <node> # manual return-to-home
    seance drill <name>    # first-class kill tests (below)
    seance config          # show effective config (fleet defaults + per-guest)

## 10. Drills are release gates

A failover system that has never eaten a real death is a liability wearing a feature's name. `DRILLS.md` ships with the module and each milestone is gated on its drill passing, timed and logged:

- **drill replication**: corrupt-free verification — restore a replica read-only on a peer, mount, diff critical paths against source snapshot.
- **drill guest**: `seance promote` of dev01's estate with charlie *administratively* killed (guests stopped, CARP demoted) — no fencing, no risk; proves the mount/register/start path and failback.
- **drill fence**: fence a *powered-on but idle* node via the real iDRAC path and verify power-off (scheduled window; this is the rung nobody tests until it matters).
- **drill node**: the real thing — pull power (or iDRAC power-off) on charlie with automation armed; measure detection→running. Target: guests up on the heir inside 5 minutes, zero human input.
- **drill failback**: return charlie, run failback, verify lineage integrity end-to-end.

## 11. Security posture

Fence credentials live in a root-only (0600) config file inside the module directory, distributed by the administrator to every node — every potential promoter can fence every potential corpse; `verify` flags divergence. Fence endpoints (BMC/iDRAC addresses) must be reachable from peer management addresses — `verify` probes this per node. `ipmitool` is a documented dependency of the shipped `fence_ipmi` driver. No secrets in snapshot names; logs redact credentials. Long-term flag (not v1): per-node IPMI users scoped to power control only.

## 12. Milestones (P5 mapping)

**M1 — repl + status** (P5.1): engine live on the existing standby lineage, cron'd, a week of observed lag stats. Gate: drill-replication.
**M2 — manual promote + failback** (P5.2): the ladder minus devd/fencing, human-invoked. Gate: drill-guest, both directions.
**M3 — CARP + devd** (P5.3): detection wired, `--auto` armed on one heir relationship only (charlie's). Gate: drill-node on charlie, automation live.
**M4 — fencing** (P5.4): ipmitool integrated, three-rung ladder complete, automation armed fleet-wide. Gate: drill-fence.
**M5 — hardening + extraction prep** (P5.5): failback runbook, DRILLS.md complete, module packaging for CBSD's ecosystem, README with the scars in it. Then the queue it unblocks: tenant zero's HBA swap in a seance-evacuated window.

## 13. The decoupling contract (open source; the first deployment is tenant zero)

seance ships with **no tenant knowledge in framework code** — no node names, addresses, counts, ports, hardware identifiers, or site vocabulary. Everything site-shaped lives in the site config: the node registry (name, mgmt address, fence endpoint + driver), the succession map, ssh port (a non-default port is a tenant fact, not a seance default), pool/dataset roots (derived from CBSD's workdir plus config, never a literal pool name), cadence/retention, notification channel. Tenant zero's site file lives in its own infra repo, not in seance's. Enforced reaper-style, because good intentions do not: a **source-as-data lint guard** in the test suite fails the build if tenant strings (site names, site IPs, hardware serials) appear anywhere in module code. Generalizations this forces beyond mere config: N-node quorum semantics (§7 rung 2, including the documented N=2 degradation), the fence-driver seam (§7 rung 4), and zero assumptions about the host's firewall (seance never touches firewall config).

## 14. Configuration UX: the file is the store, the TUI is an editor

The config is a flat, diffable text file, identical across nodes by administrative distribution — seance never propagates it (`seance verify` diffs across the mesh and flags divergence loudly; that is the whole synchronization story, by decision). On top of it, CBSD-idiomatic ergonomics: `cbsd seance setup` provides an initenv-style interactive walkthrough built on bsddialog(1) (in base; zero dependencies) that only ever *writes the file*; `seance config` prints effective values (fleet defaults + per-guest overrides); `seance config --check` validates headlessly. Everything the TUI can do has a non-interactive equivalent (`inter=0` culture) — automation-first, because open-source consumers will drive this with config management, and a TUI-only path would betray them.

## 15. Testing: the reaper-hosted portfolio

Full specification in `TESTING.md` (companion document). The summary: seance adopts the reaper project's testing methodology wholesale — the portfolio-of-oracles framing and the non-negotiables (never weaken a check to route around a defect; every fix ships with the test that would have caught it; mutation-check every new assertion; oracle self-tests written before the oracles are trusted) — and runs its pre-push battery inside reaper sessions on the proven `freebsd-15.1` guest template (15.1-p2, `releng/15.1-n283596` — byte-parity with tenant zero's fleet; vnet jails, CARP module, and full OpenZFS all proven live in the template).

Two session shapes carry the expensive tiers. **Shape A**: a pseudo-cluster of three vnet jails as nodes — real ZFS lineage, real CARP, real inter-jail ssh, real fence *semantics* via a jail-stopping fence driver, mock adapter for guest lifecycle (the guests are imaginary; everything else is real) — for cluster behavior up through the seeded simulated-cluster tier. **Shape B**: single-node adapter conformance against real CBSD (version-pinned install in the manifest's run command), driving an actual jail through the real adapter. The true-metal tiers — real iDRAC fencing, pull-the-power node death — remain fleet drills (§10), the production re-proof that reaper's own philosophy says not to simulate away. Substrate constraints honored: test datasets self-clean via trap-based teardown (the runner's rollback guard is per-filesystem and does not cover children we create under tank/state), resources declared in the manifest (4 cores / 8G for shape A), and long simulated-cluster hunts are opt-in behind TTL renewal.

## 16. Open items ⟡ (teardown agenda)

Succession map: ring (charlie←alpha) vs service-separation (bravo←alpha). Per-guest cadence defaults, and build01's bulk-window policy (pause hook vs fat deltas). CBSD module scaffolding mechanics — directory layout, verb registration, whether modules get sqlite access — to be verified against CBSD 15.0.9's module docs *before* M1, not asserted from memory. Whether `status` warns or hard-fails on kernel heterogeneity. Notification channel for the notify rung (mail? Slack webhook? both?). Name of the devd-facing shim if any (the daemonless design may need none). And the standing question every design must answer at teardown: which rung of which ladder would have failed to save us during one of this week's real incidents — walk each incident through the tree and check.

---

*Engineering discipline carried over from the migration, binding on all seance code: evidence before assertion; enumerate the class, not the symptom; checksummed releases, one canonical file; verifiers that cannot mask their own crashes; `set -u`, shellcheck, self-logging with real exit codes; and the one-shot ethos adapted — every verb ends in a verdict, and every destructive path prints its undo.*
