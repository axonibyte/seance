# seance

**A CBSD module for guest succession: replication, death detection, fencing,
and promotion.**

When a node in a bhyve/jail cluster dies, its guests come back on a survivor in
minutes — automatically where that is provably safe, and manually everywhere
else. seance is pure FreeBSD `/bin/sh`, installs as a CBSD external module, and
carries no site knowledge in its code: everything site-shaped lives in a config
file that is not in this repository.

Design rationale is in `DESIGN.md`; the testing contract is in `TESTING.md`;
the implementation brief is in `HANDOFF.md`. Installing it is
`docs/INSTALL.md`, step by step, with the CBSD source citations behind each
step.

## Status: M5 — v0.5.0

Everything the design describes is implemented and tested at every tier the
harness has. Layer 1 is live: `repl` snapshots, sends and prunes; `status` is
the one screen; `verify` renders the configuration seance expects and diffs it
against reality. On top of it, the succession ladder: `promote` walks it by
hand or from a `devd(8)` rule, `failback` runs it in reverse, `gate` withholds
a returning node's estate until the living have been asked, and `placement` is
the record they answer from. CARP carries detection — one vhid per node
identity, the advskew encoding the succession map — and the shipped
`drivers/fence_ipmi` speaks IPMI to a BMC. `setup` writes the configuration
file, interactively or headlessly, and touches nothing else.

**What that means precisely.** Tier 5 runs `lib/adapter.subr` against a real
CBSD 15.0.9 node and a real jail, and follows `docs/INSTALL.md` literally on a
clean one. Tier 6 walks the whole succession across three vnet jails with real
ZFS lineage, real ssh, real CARP vhids and a fence driver that really stops a
node. Tier 7 deals seeded events at that cluster and diffs five invariants
after every one of them. The rediscovery battery of `TESTING.md` §8 reverts
each protection this project has already paid for once and requires the harness
to notice. `sh tools/lint.sh` is the workstation half and `reaper test` the
rest; both are green.

**What is NOT proven, stated plainly, because it needs hardware and not another
test:**

| Unproven | Why, and what would prove it |
| --- | --- |
| `drill-fence` | A real BMC. `drivers/fence_ipmi` has a 177-assertion tier-1 battery against a scripted `ipmitool`, and has never powered off a machine. `docs/DRILLS.md` drill-fence is the gate. |
| `drill-node` | A real power cut on iron, with automation armed. The timings in `docs/DRILLS.md` were measured in the pseudo-cluster (`tests/tier6/drill-timing.sh`) and carry their own three caveats. |
| `drill-failback` on iron | The second half of `drill-guest`; the harness proves the mechanism, a fleet proves the fleet. |
| a `devd(8)` rule firing on a pseudo-cluster node | `devd(8)` is `KEYWORD: nojail` and does not run in a vnet jail. The link IS proven on the reaper guest's own host — the kernel emitted the CARP transition, the rendered rule matched it, and the action fired with the argument `promote-event` parses — but no tier-6 stage can make a rule fire, so the stages invoke the verb themselves. |
| a bhyve guest that has ever BOOTED | Tier 5 creates one and asserts its layout, which is all seance's own paths read; booting it needs an OS image on top of nested bhyve. |

**All five drills in `docs/DRILLS.md` are pending on a fleet** — including
`drill-replication` and `drill-guest`, whose mechanisms tiers 5–7 do prove.
That table and this one say the same thing, and neither of them is a promise
that hardware will behave: it is a list of what has not been asked yet.

M4's code is complete and M3's automation is armed only where a fleet arms it.
`v0.4.0` closed M4, `v0.3.0` closed M3, `v0.2.0` closed M2.

## The rules, and the incidents that wrote them

Everything below is a rule seance follows and the reason it exists. None of
them is a preference. Each was paid for once — by the August 2026 migration
this project is a reaction to, or by a defect the harness found while it was
being built — and each is held in place by a test that fails when the rule is
reverted.

### Every receive is `-u -x mountpoint -x canmount`, and `canmount=noauto` is set on the replica rather than received

`zfs send -p` puts the source's locally-set properties in the stream, and a
CBSD guest's dataset carries a local mountpoint. A receive without
`-x mountpoint` plants that mountpoint on the replica: a second dataset
claiming the live guest's mount, one boot away from shadowing it. That is the
August defect verbatim. `-x canmount` is not the same protection and does not
substitute for it — `canmount` is not inheritable, so a received dataset takes
the default `on` whatever its parent says, and `-x canmount` only keeps the
*source's* value out. Measured in the guest: after
`recv -s -u -x mountpoint -x canmount` a replica reads `mountpoint none
inherited` and `canmount on default`. So every tick *sets* `canmount=noauto` on
every replica dataset and inherits away any local or received mountpoint. The
tick distinguishes **enforced** (the property had never been set here, expected
once per replica dataset) from **repaired** (it had a value of its own and it
was wrong, always a warning) — because holding the law every tick would
otherwise mask a wrong receive flag, and `tests/tier6/t_repl.sh` asserts that a
first clean tick repairs *nothing*. That assertion is what the
`recv-no-x-mountpoint.patch` rediscovery row fails against; the property check
alone would not, because the repair runs before any assertion can look.

### Empty output with exit 0 is never evidence

A function that promises output and produces none has violated its contract,
and every caller treats that as a refusal rather than as a "no". This is the
crashed verifier of August encoded as a rule, and it is not a general
principle: it is four specific places, each found by running.

*Lineage.* An empty snapshot listing was read as "the newest replica is now",
so a promotion onto a replica seance could not read looked perfectly fresh.
`tests/rediscovery/verifier-masks-crash.patch` puts the `2>/dev/null` back and
two tier-4 files must fail.

*Fencing.* A driver that exits 0 having printed nothing is a contract
violation, treated as **cannot determine** — never as a verified off.

*Mounting.* `zfs mount` exiting 0 is not the dataset being mounted. The mount
ceremony asks again with `zfs_mounted` after a zero exit, because a guest
registered and started over a path nothing is mounted at boots on an empty
directory with its data sitting unmounted beside it. Injected at the wrapper —
a mount that exits 0 and mounts nothing — the ceremony used to report success.

*Placement.* A placement file that cannot be read is not a node with no claims;
see *silence is not "no claim"* below.

And one more that is the same class arriving through the replication engine: a
replica dataset that EXISTS with no snapshot of our lineage on it is not
licence to send in full. A receive always leaves the snapshot it carried, so a
dataset present without one is evidence that could not be read or a replica
somebody has edited by hand. The pair fails, naming the dataset. The half of
that defect which actually lost something was quieter: the empty answer used to
overwrite the lag record's last known timestamp, so `status` reported NONE, the
staleness clock stopped, and the one number that says what a promotion onto
that peer would cost was gone.

### Nothing is promoted until a fence has confirmed the corpse is off, and `--force` cannot buy that

Detection cannot tell dead from isolated. Two writers on diverging datasets is
the one outcome worse than an outage, so rung 4 runs the configured fence
driver and proceeds only on a verified off.

`--force=fence` does **not** skip the rung. A configured driver is invoked every
time, force or no force; what the force overrides is the *cannot determine*
family — no driver configured, no driver installed, an endpoint that did not
answer, a timeout, or a success with nothing to say. A driver that answers
*refused* or *still on* aborts whatever the operator typed. The reason is not
strictness for its own sake: the rule "a fence that refused aborts even under
`--force`" is only true if the driver actually runs under force, and a force
that skipped the rung would make that case unreachable. It is also the safer
reading of the word — forcing means "I accept that this could not be
confirmed", never "do not try". The stated cost is that `--force=fence` against
a node with a slow BMC now waits out `fence_timeout`, which is the right price.

`--force=probes` is a usage error and always will be: rung 3 pings and sshes
the "dead" node, and any answer at all aborts. A host that answers is never
fenced by force.

### seance never copies its own configuration between nodes

The file names how to power a machine off. Automatic propagation of that is a
footgun — one node's edit becomes every node's fence credentials — so
distribution is administrative and `verify` diffs the file across the mesh and
says so loudly when it differs, in a way that changes the exit code rather than
in a footnote. That diff is the entire synchronisation story.

The rule has a consequence that shapes the vocabulary: because the file must
stay byte-identical across the mesh, anything that is one node's own fact about
its own layout has to be sayable *as* that node's key. That is why a node's own
`standby_root` and `carp_interface` exist beside their fleet defaults, and why
the fleet `standby_root` carries a `%n` substitution for the receiving node's
key: a fleet whose nodes do not share a pool name or an interface name could
not otherwise be described by one file.

### The boot gate withholds a guest in the platform's own slave mode, from an rc(8) unit ordered before the platform's daemon — because a hook cannot veto

The obvious lever was a per-guest `master_prestart.d/` hook. It cannot work,
and that was read out of the platform's source before anything was built on it:
`jstart` and `bstart` call the hook runner as a bare statement and never test
it, and the runner executes each hook inside a `find | while read` pipeline and
then restores its environment, so it returns 0 whatever the hook returned.
Reproduced live with the same construct. A hook can observe and notify; it
cannot stop a start.

What can is the platform's own "this guest lives elsewhere" flag — slave mode,
which its own cold-migration path sets on the source after a migration. The
start paths refuse a guest in it by name, the autostart ordering skips it, and
it survives the reboot it was written for because it is in the platform's
database. Releasing it prints a one-line undo.

The unit is ordered `BEFORE` the platform's daemon because the autostart is not
an rc(8) unit at all: it has no `PROVIDE` line and is never run by rc(8); it is
started from inside that daemon's prestart. And the unit cannot veto by failing
either — rc(8) does not stop later services when one exits non-zero — so it
does not try: it marks each withheld guest and lets the platform refuse them. A
non-zero exit is a loud log line, not a lever.

**No peer answering at all withholds the whole estate.** A node that can reach
nobody must assume it is the isolated one.

### The rc.d unit, the crontab line and the mesh link all name the platform's verb, never `bin/seance`

`bin/seance` is the dispatcher, and it learns which node it is on — where the
configuration is, where the state directory is — only from the variables the
module's own verb wrapper exports. Three places told the platform to run it
directly, and every one of them was silently broken until M5 ran
`docs/INSTALL.md` literally on a clean guest:

- the boot gate's rc(8) unit resolved the platform's verb symlink and then
  walked *past* it, so the gate exited 2 at every boot and **the estate was
  never gated** — the one thing the unit exists for;
- `verify --render cron` rendered a line naming `bin/seance`, so cron ran it
  with cron's own environment, it exited 2, and **a freshly installed node
  replicated nothing, for ever** — while `verify` reported the crontab line as
  correctly installed, because the check compares the file against the same
  rendering;
- README and `docs/INSTALL.md` told the operator to link `bin/seance` onto the
  mesh's `PATH`, so a placement query over ssh exited 2 and **every peer read
  as a node that could not report** — which is not "no claim", so the gate
  withheld whole estates, `promote` aborted and `failback` refused, fleet-wide,
  because of an install instruction.

The rule is one sentence — everything that names how to run a seance verb from
outside the platform's own dispatch asks the adapter (`adapter_fact`) how this
platform runs one — and the proof it was already known is that
`verify --render devd` had always done exactly that, because a `devd(8)` action
is executed with an environment nobody set. Three call sites had not.

### `written@` is a lie until the pool has committed

`seance failback` pulls the reverse incremental into the origin's *live*
dataset with `zfs recv -F`, which rolls the destination back before rolling it
forward. Before that it measures what has been written to the origin since the
incremental base, on every dataset, and refuses — printing the byte count —
unless the operator says those bytes are debris.

ZFS space accounting is exact only once a transaction group has been written
out. Measured in the guest: snapshot, write a megabyte, and the measurement
reads 0; `zpool sync`, and it reads 1122304. So the guard read before the pool
committed would return 0 — seance would have told an operator there was nothing
to lose and then destroyed their data, with the guard reporting success. The
failure was in the one direction a guard must never fail. `failback` now syncs
the pool before it measures anything, and a sync that fails fails the plan
rather than producing numbers, because an untrustworthy byte count reads as
"nothing to lose".

It was found because the guard runs twice — a pre-flight before anything is
stopped, and again authoritatively after the final snapshot — and the two
measurements of the same datasets against the same base disagreed. Without the
pre-flight the undercount would have stayed in the product.

### Sends are per dataset, never `-R`, never `recv -F` in the forward direction — and a promotion's instant is the newest snapshot common to *every* dataset of the guest

`-R` produces a replication stream, and an incremental replication stream is
only receivable in practice with `-F`, which `zfs-receive(8)` defines as
"destroy snapshots and file systems that do not exist on the sending side".
seance holds no such authority over a peer's pool: a foreign tool's snapshot on
a replica is not seance's to destroy, and neither is a dataset seance did not
create.

The cost is stated rather than discovered later: a dataset destroyed on the
source is not destroyed on the replica, a guest that gains a dataset gets one
full send of it, and **a tick that dies part way leaves a guest's datasets at
different snapshots**. That last one was observed in
`tests/tier6/t_interrupt.sh`, where a killed root send left the small child
dataset a snapshot ahead.

So crash consistency is per instant and not per dataset: promotion chooses the
newest timestamp present on ALL of a guest's replica datasets, rolls any
dataset that is ahead of it back to that point — loudly, naming every discarded
snapshot, with the undo stated as impossible — and reports the RPO of the
common point. A guest with no timestamp common to all its datasets is an abort,
and it is not forceable: that is not a stale replica, it is an incoherent one.

### A jail's configuration does not travel in its own datasets, so seance carries it in one extra dataset per node

Rung 6 registers a guest from the rcfile in its system directory. On real CBSD
a **bhyve** guest works, because its system directory is a symlink into the
VM's own dataset. A **jail**'s is a plain directory on the platform's workdir
dataset, outside the guest's dataset — correctly not replicated — so
registration had no rcfile to read and a survivor held a jail's data with no
way to start it.

So each node owns one extra dataset, mirrored from the platform's system
directory before every tick and replicated to the same heirs under the same
snapshot grammar; at promotion it is mounted read-only, the guest's directory
copied out, and the mount put back. The wire protocol is unchanged — datasets
and snapshot names, nothing asked of the dead — the platform's own directories
are not moved, and host configuration never lives inside a jail's root where a
compromised jail could rewrite its own promotion parameters.

"Already travels" is **measured, not assumed by platform**: the mirror asks
whether the guest's system directory resolves to somewhere at or under one of
that guest's own dataset mountpoints. That is true for a VM on CBSD and for
every guest in the pseudo-cluster, and false for a jail on CBSD — and testing
the mountpoints rather than the type is the only form that does not put
platform knowledge back into the replication engine.

The pseudo-cluster's guests all carry their configuration inside their own
datasets, so tier 6 can only assert the mechanism. That a real jail registers
and starts out of it is tier 5's, and it does.

### Three platform behaviours on 15.1 that reading the source alone would not have settled

*The platform cannot be asked a guest's type.* Its `emulator` tool quotes the
guest name with double quotes in its SQL; SQLite 3.53.3 rejects double-quoted
string literals, and through the platform's own SQL builtin the parse error is
swallowed and the call returns empty output with rc 0 — which the script reads
as "no row". On a real node every guest "did not exist", and every adapter
function that goes through the type was answering about a guest that was not
there. The type now comes from the guest's own listing row, which the adapter
was already reading.

*A guest listing's name predicate does not reach its unregistered area.* That
area walks every file in the platform's rcconf directory, outside every
predicate, so a node that has been through one unregister prints a phantom row
for that guest in every listing for ever — and a query for a name no guest has
prints another guest's row. The adapter filters the listing by name itself, and
`adapter_guest_unregister` removes the export the platform's own unregister
wrote on its way out. Nothing that predated the call is destroyed: the file
removed is always one this very call caused to be written.

*The platform's mutating verbs talk on stdout, refusals included.* Starting a
guest held in slave mode exited 1 having put the refusal on **stdout** — the
channel this project reserves for data, from a function whose contract promises
none, so a caller capturing the answer got the platform's chatter as its
answer. Every adapter function marked `[no output]` now runs the platform with
stdout redirected to stderr. The refusal is not discarded: one an operator
cannot read is worse than one on the wrong descriptor.

### `verify` FAILS a node whose CARP preemption sysctl is not 1

Read from the kernel rather than assumed: a backup takes over from a master
that is advertising more slowly **only** when `net.inet.carp.preempt` is set,
and its default is 0. seance's whole detection model is that the advskew *is*
the succession map, so the default is wrong for it — and the way it goes wrong
is invisible. A node reboots, or its link flaps while it is down, and comes
back BACKUP; its heir is MASTER for the returning node's own vhid and stays
there; and the returning node's next real death produces **no CARP transition
at all**, because the heir is already MASTER. `devd` never fires and the death
is never detected, with every other check green.

That is why it is a FAIL and not a warning. The unscheduled-replication check
warns, because a missed tick is visible in `status` the next time anybody looks;
this one reads correct until the second death. Persistence gets its own
separate warning: a node whose sysctl is right now and absent from
`/etc/sysctl.conf` is a node that is wrong after a reboot.

### `timeout(1)` reaps descendants, so the launcher of a detached promotion needs `--foreground` and nothing else does

`promote-event` bounded its `daemon(8)` call with the ordinary timeout wrapper.
`timeout(1)`'s IMPLEMENTATION NOTES: without `--foreground` it runs as the
reaper of the command *and its descendants* and waits for all of them. So the
bound did not apply to the launcher, it applied to the promotion —
`promote-event` blocked for the whole timeout, and `devd(8)` waits for its
actions, so every other CARP transition on the node queued behind it, including
the ones about a second death; and at the deadline the detached ladder was
SIGTERMed part way through whatever it was doing. Found by the tier-6 `quorum`
stage's first real run, where the freeze half passed and every assertion after
it failed together.

Every other caller in seance wants the reaper behaviour and keeps it: a fence
driver that spawns a child must have the whole subtree killed at the deadline.
The load-bearing assertion in the test is on the wall clock, because both
behaviours produce a process and only one of them returns.

### Silence from a peer is not "no claim"

A living peer that cannot state its placement — seance not installed, the verb
erroring, a half-written reply — is counted as SILENT, and every reader takes
the fail-safe branch: the gate withholds the whole estate, `promote` aborts
naming the peer and is not forceable, `failback` refuses.

Before that, the gate counted a peer as reached when the ssh probe succeeded,
and the placement query's failures went to stderr and were dropped. **A peer
that was up with a broken seance made its guests look unclaimed**: the gate
released them, the ladder promoted them, and the guest came up in two places.
The split brain the gate exists to prevent, arriving by way of a broken install
rather than a broken network.

The same rule one layer down: a placement file that does not parse — a torn
line, a stray field, a CR from an editor — fails the read and names the line by
number. There is no way to guess which half of a torn line was lost, and a
wrong guess is a guest in two places, so `placement_home` has a third answer
(claimed / not claimed / **cannot tell**) and every caller says so.

The cost is stated: one node with a broken seance freezes promotions and
failbacks fleet-wide until it is fixed or taken out of the configuration. That
is the fail-safe direction, and every refusal prints the command that diagnoses
it.

### Quorum is `1 + reachable_others > N/2`, and the freeze is the point

Count yourself, then a strict majority of the configured cluster. N=3 with one
dead acts (2 > 1.5). N=4 with one dead acts (3 > 2). A clean 2–2 half-split
freezes: nobody acts, automation stops at notify, and a human resolves it. N=2
cannot form a quorum the moment its peer dies, and degrades to notify plus a
human running `--force=quorum`. A node that can reach nobody must assume it is
the isolated one and does nothing, loudly. A witness making the voting
population odd is documented as the recommendation for even-N sites and is not
implemented at v1.

The freeze sacrifices availability and never consistency, which is the trade
this product exists to make.

And the arithmetic counts **keys**, which is why `config --check` refuses two
node keys sharing one management address. A copy-pasted address makes one
living host answer twice: a four-node fleet with a single surviving peer
computed `1 + 2 > 2` and acted where the honest arithmetic freezes — and the
validator said PASS.

### A lag record more than `skew_tolerance` in the future makes the guest due, with a warning

`repl` skips a guest whose newest lag record is younger than that guest's
cadence, and the record carries the tick's own epoch. So on a node whose clock
has jumped **backwards** — ntp stepping after a long outage, a hypervisor
restoring a paused guest, a BIOS clock read wrong at boot — every guest is "not
due" until wall time catches up. Found by the simulator: a skew of −180 s
against a 60 s cadence cost three consecutive ticks.

Nothing was destroyed and nothing was promoted, and that is exactly what made
it dangerous. The tick exits 0 and its verdict line reads like a healthy tick
with the cadence gate doing its job:

```
repl: 1 guests x 0 pairs, 0 ok, 0 failed, 1 skipped, 0 in progress
```

A fleet whose clock stepped back an hour would replicate nothing for an hour
and page nobody. So the comparison runs in both directions: a record in the
future by more than `skew_tolerance` is due, with a warning naming the guest,
both epochs and the tolerance. Within the tolerance it stays not-due, silently
— that is ordinary jitter and the gate working. `skew_tolerance` is the
boundary rather than a new number because it is the line this configuration
already draws between jitter and clocks that disagree, and replicating is the
safe direction: a snapshot is taken, the peers receive it, nothing is destroyed
and nothing is promoted.

### `promote-event` refuses what is not an event, runs one ladder per corpse, and waits for nobody's notification

Three rules at one entry point, all written by one fact: `devd(8)` runs an
action by forking a shell and *waiting* for it, and this verb runs as root out
of a rule file.

*An argument that is not a CARP subsystem is a contract error.* A vhid outside
1–255, a vhid spelled with a leading zero, and an interface name outside
`[A-Za-z0-9._:-]` or longer than 15 characters are all refused with exit 2.
Before that, an impossible vhid, an argument carrying a command substitution,
and one carrying a newline were every one of them answered with "belongs to no
node in this configuration; nothing to do" and exit 0 — the same answer, in the
same words, that a genuinely foreign vhid gets on a shared segment. That answer
is right there and wrong here: this is a rule that was mistyped or copied from a
fleet that numbers its nodes differently, being told nothing is wrong. Nothing
was ever executed — there is no eval and no shell in the path — so it was not an
injection; it was a verb that could not tell an event from a string. A vhid
*inside* the range that this configuration does not claim is still exit 0 and
still pages nobody.

*One ladder per corpse.* A flapping link emits MASTER, BACKUP and MASTER again
inside the debounce the first event is still serving, and every armed event
detached another promotion: measured, two events for one vhid started two
ladders. Each was correct on its own, and each mounted, registered and started
the same estate. The detached command now runs under a lock named after the
dead node; the loser exits and no second ladder runs. The narrowing is stated:
per corpse, and on the automatic path only — a human typing `seance promote`
twice is not serialised by this.

*The notification is sent from a child the verb does not wait for.* A site's
`notify_cmd` is bounded at 30 s, and the verb used to wait for it — blocking
`devd`'s entire event loop for thirty seconds, and the events queued behind it
are the ones about the second death. Nothing about the notification changed:
same level, same subject, same body, the same bound around the site's script.
The narrowing is again stated: only this verb, because every other notifier in
seance sits inside something that already takes minutes.

And the configuration half of the same failure: a node whose `auto_promote`
names a peer must resolve a `carp_interface`, its own or the fleet's. Without
one there is nowhere to put the alias that carries the corpse's vhid, so
nothing can ever make that node MASTER for it: the automation is switched on
and deaf, and every other check is green. It is the same shape as the
preemption failure above, and it is visible in a file that is byte-identical
across the mesh, so the check an operator runs before deploying is where it
belongs.

### `seance setup`'s wizard draws on the terminal and reads its answer from the other stream

`bsddialog(1)` prints the user's input to **stderr** by default and `--stdout`
moves that input — the drawing does not move, because it is an ncurses program
and ncurses draws on stdout. Every screen captured stdout, so the command
substitution received the entire ANSI screen with the answer appended and the
terminal received nothing. Measured: one question wrote 1441 bytes of terminal
control into the configuration as the value of `cadence`, and the
node-selection loop — which stops on a *blank* answer — never saw one, so the
wizard ran for ever on a blank screen.

It had never been run. The file said so: "bsddialog needs a real terminal;
there is no `script(1)` harness for it here." `script(1)` is in the base system
and gives exactly the terminal the wizard asks for, which is how M5 found this
and why `tests/tier1/t_setup_wizard.sh` now drives the whole walkthrough under
a pty and requires the file it writes to be the file the headless path writes
from the same answers.

## Verbs

| Verb | What it does | Exit 0 | Exit 1 | Exit 2 |
| --- | --- | --- | --- | --- |
| `repl` | one replication tick; the crontab target | every pair attempted succeeded | any pair failed | configuration or contract error |
| `status` | the one screen | every replica fresh, the mesh agrees | any warning | configuration invalid, or this node is not in it |
| `verify` | render what seance expects, diff it against reality | everything PASSes | anything WARNs or FAILs | the configuration could not be validated |
| `promote` | the succession ladder | the estate was promoted or correctly stood down | the ladder stopped | usage or configuration error |
| `promote-event` | **internal**: the `devd(8)` target | any event it understood, whatever it decided | — | the argument is not a CARP subsystem |
| `failback` | bring a guest home | the guest is home and running | the failback stopped | usage or configuration error |
| `failback-assist` | **internal**: the interim host's half | the step was taken | the step failed | usage or configuration error |
| `gate` | the resurrection gate | nothing is withheld | anything is withheld | usage or configuration error |
| `placement` | which guests this node hosts away from home | the records were read | `--remote`: a living peer could not report | configuration error |
| `config` | print the effective configuration; `--check` validates it | the configuration is valid | it loaded and is invalid | it could not be found or parsed |
| `setup` | write the configuration file | a configuration was written | it was refused | usage error, or a file that does not parse |
| `version` | **data-only**: print the version | — | the version file is missing or empty | any argument at all |
| `help` | **data-only**: the usage summary | always | — | — |

`0` ok, `1` operation failed, `2` usage or contract error, everywhere. stdout
is data, stderr is diagnostics, and **every verb that acts on the fleet ends in
a verdict line, which is the LAST line it prints.** `version` and `help` are
the two data-only verbs: they print the version and the usage summary and
nothing else, which is what makes the version usable inside a shell
substitution.

Every verb the dispatcher answers to has a section below, and every section
names a verb the dispatcher answers to. `tests/tier3/t_verb_docs.sh` asserts
both directions against the source, and `tests/tier1/t_verb_flags.sh` asserts
the same for every verb's *flags* against the usage text — so a verb or a flag
added without a line an operator can find fails the suite.

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
override, and never the guest's own home. Each pair runs under `lockf(1)`, so a
tick that finds a pair already running logs it and moves on rather than
overlapping.

Each tick also mirrors what the guests' own datasets do not carry. A jail's
registerable configuration lives outside the guest's dataset, so `repl` copies
it into one extra dataset per node — `<pool-of-jails-data>/seance-sys`, mounted
at `<state-dir>/sys` — and replicates that dataset like a guest, to the same
heirs. Without it a survivor would hold a jail's data and have no way to
register it. A VM needs none of this: the platform already symlinks its
configuration into its dataset.

Verdict line:

```
repl: 2 guests x 3 pairs, 3 ok, 0 failed, 0 skipped, 0 in progress
```

`--locked` is internal: it is how the tick re-enters itself under the lock, and
it does exactly one pair without taking a snapshot.

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

Verdict line:

```
status: 3 guests, 6/6 replicas fresh, 0 warnings, 0 failures
```

A record type keeps its column count in `--tsv`, whatever the fleet's state: an
unreachable peer prints `unknown` and the reason where a reachable one prints
its kernel and checksum, because a parser that breaks on the day a peer went
away breaks on the only day it mattered.

### seance verify

Render the configuration seance expects, and diff it against reality:
`config --check`, the mesh reachability matrix, the pairwise clock delta, one
configuration file across the whole mesh, this node's standby parents on every
peer, and the crontab line.

```sh
seance verify
seance verify --render cron        # the expected crontab(5) line
seance verify --render carp        # the expected rc.conf(5) CARP configuration
seance verify --render devd        # the expected devd(8) rules
seance verify --render devd > /usr/local/etc/devd/seance.conf
```

All three renderings need the platform: `carp` and `devd` because which vhids a
node carries depends on which node it is, and `cron` because the line names the
command cron will run with an environment of its own, and only the platform can
say what runs a seance verb there.

What the CARP check compares, and against what:

| Check | Against |
| --- | --- |
| one `ifconfig_<if>_alias<n>` per vhid this node takes part in | every `ifconfig_<if>_alias*` variable `sysrc(8)` reports, at any index |
| the advskew on each: 0 own, 100 heir-of, 200 second-heir-of | the same |
| the vhid is live and in the state it should be | `ifconfig(8)`, through the adapter |
| `carp` loads at boot | `kld_list` or `/boot/loader.conf`; neither is a warning, because the module may be in the kernel |
| the file carrying `carp_pass` is not group- or world-readable | `stat(1)` |
| a `devd(8)` rule per vhid this node may **inherit** | `/usr/local/etc/devd/seance.conf` or `/etc/devd/seance.conf` |
| `devd` is running | `service devd status` |

A missing devd rule is a **FAIL** when this node's `auto_promote` names the
node whose vhid it is, and a warning otherwise: a node told to act by itself
and unable to hear about the death is an arrangement somebody believes is in
place, and a node that would only have notified has merely lost a notification.

**`verify` never writes anything** — not the crontab, not a ZFS property, not a
configuration file. It prints what it expects and where reality differs,
because a verifier that repairs is a verifier whose green run says nothing
about the state it was asked to check.

### seance promote

The succession ladder, for a node that has died. Seven rungs, every one of them
logged with its own verdict and reason, every one of them able to stop the
whole thing, and one verdict line at the end.

```sh
seance promote alpha                       # walk the ladder for alpha's estate
seance promote alpha --guest web01         # one guest of it
seance promote alpha --force=fence         # accept a fence that could not confirm
seance promote alpha --force=quorum,lineage
seance promote alpha --force               # every forceable rung
seance promote alpha --auto                # what devd runs; no human anywhere
```

| Rung | What it asks | What stops it |
| --- | --- | --- |
| 0 arming | `--auto` only: is the fleet key `auto` 1 **and** does this node's `auto_promote` name the corpse? | either switch off aborts, before anything waits or fences |
| 1 debounce | is the trigger still true? | manual: `n/a`. `--auto`: wait `debounce`, then this node must still be CARP MASTER for the dead node's vhid, or it was a link that flapped |
| 2 quorum | `1 + reachable_others > N/2`? | a freeze is `notify`, and `--force=quorum` is the documented N=2 / even-N escape |
| 3 probes | does the dead node answer ping or ssh? | **any** answer aborts, and no `--force` can reach this rung |
| 4 fence | did the driver verify it off? | refused/still-on aborts and pages; cannot-determine notifies |
| 5 lineage | per guest: whose is it, does anybody already claim it, is the replica fresh, is the fleet kernel-homogeneous? | a stale replica is `force-only`; no replica at all aborts |
| 6 promotion | mount in place, relink, register, start, verify, record | a guest that will not start fails alone; the others continue |
| 7 post | what the next `repl` tick will do | nothing; there is nothing to configure |

**`--force` names rungs, and skips exactly the ones it names** — every rung it
overrides says `forced` in its own line. The forceable rungs are `quorum`,
`fence`, `lineage` and `kernel`. `--force=probes` is a usage error, and
`--force=fence` does not skip the fencing; both are explained under *nothing is
promoted until a fence has confirmed the corpse is off*, above.

Promotion is **in place**: the replica stays where replication put it, under
`<standby_root>/<dead>/<guest>`, and is given the mountpoint the platform
expects. A guest whose configuration did not travel inside its own datasets — a
jail — has it restored from the dead node's configuration mirror, which is
mounted read-only for the copy and put back afterwards; a guest whose
configuration did travel is registered straight from the replica. Every
mutating step prints its undo. Each guest reports its RPO — the age of the
newest replica snapshot at the moment it was promoted, which is exactly what
the promotion cost.

**`--auto` is the devd path, and rungs 1–4 must all be green on it.** That is
true by construction rather than by inspection: `--force` may not be combined
with `--auto` (exit `2`), so there is no way to reach rung 5 past a quorum that
did not form, a host that answered, or a fence that could not confirm. When an
automatic run stops anywhere past fencing, one notification goes out at
`crit` — rungs 2, 3 and 4 already page for themselves, and rung 1's transient
master deliberately does not, because a link that flapped and a seance that did
nothing is the rung working.

**A guest whose per-guest heir names another node is `deferred`, and pages.**
CARP hands a dead node's vhid to that *node's* heir, while the ladder resolves
succession *per guest*, so a `guest_<g>_heir` override can name a node no CARP
transition wakes. On the automatic path that guest is reported as `deferred`
rather than `stand-down`, the run's disposition and exit status say so, and the
notification carries the exact command the responsible node has to be given —
`seance promote <deadnode> --guest <g>`. `seance config --check` warns about the
combination in advance (a `warn:` line; the verdict stays `PASS`, because the
arrangement is legal and a node has to be able to run on the file). A manual
promotion still says `stand-down`: there is a human reading the line.

### seance promote-event

**Internal.** What a `devd(8)` rule runs, once per CARP MASTER transition. It
is documented because an operator debugging a rule will run it by hand.

```sh
seance promote-event 1@vtnet0
```

It maps the vhid to a node and then either detaches the automatic promotion
with `daemon(8)` under a per-corpse lock, logging to syslog under the tag
`seance`, or notifies at `crit` and does nothing. A vhid no node in the
configuration claims, and this node's own vhid, are both "nothing to do" and
not errors — CARP is a broadcast protocol and somebody else's cluster may share
the segment, and becoming MASTER for one's own identity is what booting looks
like. What is *not* "nothing to do" is an argument that could not have come
from the kernel; see the rule above.

**It is bounded, and that is a requirement.** `devd(8)` runs an action by
forking a shell and *waiting* for it, so its whole event loop is blocked until
this verb returns — which is why the promotion is detached rather than run
here, and why the notification is too.

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
syncs the pool, measures what has been written since that base on every
dataset, and **refuses, printing the byte count**, unless
`--discard-origin-writes` says the operator has looked at those bytes and
decided they are debris. The decision is recorded in the succession record.

The refusal usually costs nothing, and that is deliberate: the measurement runs
as a pre-flight before anything is stopped, so a refused failback normally
leaves the guest running on the interim host. A guard whose refusal costs an
outage is a guard people learn to route around, and this is one seance wants
operators to hit. `docs/RUNBOOK-failback.md` is what to read when they do.

### seance failback-assist

**Internal.** The interim host's half of a failback, invoked over the mesh by
the origin. It is documented because the operator finishing a half-failed
failback by hand needs it, not because anything else should call it.

```sh
seance failback-assist web01 stop         # stop it here
seance failback-assist web01 start        # put it back, if a failback was refused
seance failback-assist web01 snapshot     # final snapshot of this node's lineage
seance failback-assist web01 unregister   # unregister, unmount, mountpoint=none
seance failback-assist web01 release      # drop the claim, close the record
```

These are also the undo lines `seance promote` prints beside the steps it
cannot otherwise reverse — an undo has to be a command somebody can type, and
prose is not one.

### seance gate

The resurrection gate (`rc.d/seance_gate` runs it before the platform's
autostart). For every guest whose home is this node, it asks each **living**
peer whether that peer already claims it. Any claim withholds that guest. **No
peer answering at all withholds the whole estate** — a node that can reach
nobody must assume it is the isolated one.

```sh
seance gate                     # withhold what must be withheld
seance gate --check             # say what it would withhold; change nothing
seance gate --release web01     # release one guest, if no peer still claims it
```

A guest is withheld by putting it in the platform's slave mode, which survives
a reboot because it is in the platform's own database:

```
gate: HELD <guest> -- <peer> claims it
```

`seance failback` releases it; so does `--release`, which refuses while a peer
still claims the guest, while no peer answers, or while a living peer could not
report its placement at all.

### seance placement

Which guests this node is hosting **away from home** — the claim the gate and
the ladder read.

```sh
seance placement            # this node's claims
seance placement --remote   # the same, gathered from every living peer
```

Records are one guest and its home per line, tab separated, with the peer's own
key added by `--remote`, and then a verdict line. The local form deliberately
needs no adapter: it is what every peer runs over ssh to answer "are you
holding one of mine", and a node whose platform is not up must still be able to
answer.

**A peer that cannot answer is named, not skipped**, and **a record it cannot
read is not a record that says "no claim"** — both are the rule above.

**Mesh prerequisite:** this verb must be runnable as `ssh_user` on every node —
a link to the module's **verb wrapper** (the `seance` file at the module root)
somewhere on that user's `PATH`. Not to `bin/seance`: the plain dispatcher is
not told which node it is on, and a peer that answers `no config file` is a
peer that could not report.

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

A mistyped key is not a key seance ignores — it is a setting the operator
believes is in force and is not — so an unknown key stops the load, every fault
in the file is reported rather than the first one, and a failed load leaves
nothing behind at all.

### seance setup

The configuration UX from design §14: **the file is the store, the TUI is an
editor.** `setup` walks site defaults, then the fleet, then each node, then
any per-guest overrides, then a review — and **only ever writes the target
file.** It never touches the system, and it runs `config --check` on the
result before writing, refusing an invalid configuration unless told
otherwise.

```sh
seance setup                                     # the interactive walkthrough
seance setup --out /path/to/seance.conf          # write somewhere other than
                                                  #   the default target
seance setup --from /path/to/seance.conf         # edit an existing file
```

**Every screen has a non-interactive equivalent** — the `inter=0` culture
carried over from the platform's own initialisation:

```sh
seance setup --non-interactive --set cadence=600 --set node_alpha_mgmt=alpha-mgmt.example.net --out /tmp/seance.conf
seance setup --non-interactive --answers answers.conf --out /tmp/seance.conf
seance setup --dump-answers answers.conf         # interactive, but also
                                                  #   records the answers
seance setup --non-interactive --from /path/to/seance.conf --allow-invalid
```

`--set key=value` repeats and is applied last, after any seeding —
the answer key IS the config key (`cadence`, `node_alpha_mgmt`,
`guest_web01_heir`, ...), so an `--answers` file is nothing more than
`seance.conf` grammar and there is no second vocabulary to keep in sync with
the first. `--from <file>` and `--answers <file>` are the same mechanism under
two names: `--from` points at a real deployed configuration to edit or
replay, `--answers` at a file `--dump-answers` produced; given both,
`--answers` is applied second and wins on any key both name.

`--allow-invalid` writes even when `config --check` would refuse the result —
the problems are still printed, and the verdict line says the file is invalid.
Without it, `setup` writes nothing and exits `1`. Overwriting an existing
target backs it up first and prints the undo:

```
setup: wrote /tmp/seance.conf (PASS)
```

Without a terminal, `setup` refuses rather than hanging: a configuration
management run that forgot `--non-interactive` gets an error and not a process
waiting for a keystroke nobody will type.

### seance version

Print the module's version, from the `VERSION` file beside it. Exit `1` if that
file is missing or empty — a version seance cannot state is not a version it
may guess — and exit `2` on any argument at all, because a verb that quietly
ignores an argument is a verb somebody will one day pass `--tsv` to and then
parse the answer as TSV.

```sh
seance version
```

### seance help

Print the usage summary: the verbs, every flag each verb accepts, where the
configuration file is looked for, and what the exit codes mean. `seance --help`
and `seance -h` are the same verb.

```sh
seance help
seance --help
```

## Configuration

The configuration file is `$SEANCE_CONF` if set, otherwise
`$SEANCE_CBSD_WORKDIR/etc/seance.conf` — which is `~cbsd/etc/seance.conf` on a
node running under CBSD. It is flat text, one `key=value` per line, **parsed
and never sourced**; a line whose first non-blank character is `#` is a
comment, there is no quoting, and the value is the rest of the line with
trailing whitespace removed. `etc/seance.conf.sample` documents every key with
its default and is itself checked by the suite.

The same file is on every node, byte for byte. Keys are lowercase with
underscores; a node or guest key inside one is lowercase alphanumeric, and
`names_alpha` (for a node or guest key `alpha`) maps it to a display name where
the real one differs.

### Fleet keys

| Key | Default | Range | Per guest | What it is |
| --- | --- | --- | --- | --- |
| `cadence` | 900 | 60–86400 | yes | seconds between replication ticks for a guest |
| `retention_recent` | 14400 | 60–31536000 | | everything younger than this is kept |
| `retention_hourly` | 172800 | 60–31536000 | | between the two, the newest snapshot of each UTC hour survives |
| `staleness_max` | 3 × that guest's cadence | 60–604800 | yes | how old a replica may be before promotion calls it stale and demands `--force=lineage`. At exactly this age it is still fresh |
| `skew_tolerance` | 120 | 0–3600 | | how far a timestamp may be into the future before it is clock skew rather than freshness. A tolerance, not a substitute for NTP |
| `debounce` | 45 | 0–3600 | | seconds an automatic promotion waits before re-checking the transition that woke it |
| `fence_timeout` | 60 | 1–3600 | | seconds a fence driver has to prove a node is off |
| `ssh_user` | root | | | the user node-to-node ssh runs as |
| `ssh_port` | 22 | 1–65535 | | 22 because that is ssh's port; a site that moves it says so here |
| `ssh_extra_opts` | unset | | | extra options passed verbatim to every ssh and transport. It can ADD what ssh understands and cannot replace what seance set: ssh takes the first value for each parameter, so seance's own batch mode and connect timeout win |
| `standby_root` | derived at run time | | | where replicas land, under the receiving node's key. `%n` in the value is that node's key |
| `notify_cmd` | unset | | | run for every notification, subject as `$1` and body on stdin. Its exit status is logged and never fatal — a promotion must not die because mail did. Unset means syslog only, and that is the whole notification feature |
| `witness` | unset | | | documented for even-N sites and **not implemented at v1** |
| `carp_interface` | unset | | | the interface the vhids run on. Required as soon as any node carries a vhid, or is armed to succeed one |
| `carp_pass` | unset | | | the CARP shared secret. Unset means unauthenticated advertisements, which `verify` warns about |
| `auto` | 0 | 0–1 | | whether this fleet may promote without a human at all. One of the two switches; the other is per node |

### Per-node fields

Written as `node_<key>_<field>`:

| Field | What it is |
| --- | --- |
| `nodename` | that node's platform node name. Required; it is how a running node recognises itself in this file |
| `mgmt` | the address peers reach it on. Required, and it must be that node's alone — everything that counts nodes counts keys |
| `heir` | the node that inherits its guests |
| `heir2` | the node that inherits them if the first heir is itself unreachable |
| `fence_driver` | which fence driver to use against this node |
| `fence_target` | the name of an ENTRY that driver looks up, not an address. For the shipped IPMI driver it is a token naming a block in the driver's own credentials file — see `docs/fence-drivers.md` |
| `standby_root` | this node's own opinion of where replicas landing on it go; beats the fleet key and its `%n` |
| `vhid` | the CARP virtual host ID standing for this node's identity, 1–255, unique across the fleet |
| `vhid_ip` | the address that vhid carries, with a prefix length. A heartbeat token, not a service address |
| `auto_promote` | the dead-node keys THIS node may promote without a human. Space separated; empty is notify-only |
| `carp_interface` | this node's own interface for the vhids, beating the fleet key |

### Per-guest overrides

Written as `guest_<key>_<field>`, and only four fields: `cadence`,
`staleness_max`, `heir` and `heir2`, for guests that want something different
from the fleet. A guest that names its own heir replaces its home node's
succession **entirely**: naming a first heir means the succession has been
thought about, and quietly appending the node's second heir behind it would
restore the arrangement the override was written to escape. A second heir
without a first is therefore an error and not a half-override.

### What `config --check` refuses, beyond the ranges above

- `staleness_max` below `cadence` (every replica would be stale at birth), and
  `retention_hourly` below `retention_recent` (the hourly rung would be
  unreachable);
- two node keys sharing a `nodename`, a `mgmt` address, or a `vhid`;
- a node that carries a vhid and resolves no `carp_interface`, and a node whose
  `auto_promote` names a peer and resolves no `carp_interface`;
- an `auto_promote` naming this node itself, a node that does not exist, a node
  this one may not inherit, or one with no vhid for a transition to fire on;
- an unknown key, a duplicate key, a CRLF line ending, and a multi-word value
  where one word is meant.

It **warns**, without changing the verdict, about a per-guest heir override
that is not some node's own heir while `auto` is 1 — the deferral case above.

## Running the tests

The portfolio (`TESTING.md`), tier by tier, with the count each tier carries in
this tree.

| Tier | Where | What it is | Count | How to run it |
| --- | --- | --- | --- | --- |
| 1 | workstation | pure units: the policy engine, the config parser, the dispatcher's own surface, the simulator's generator/model/shrinker, the fence driver, the setup wizard under a pty, the upgrade path | 1357 | `SEANCE_TIERS=1 sh tests/run.sh` |
| 2 | workstation | golden vectors: snapshot names, timestamps, the config corpus — each run normally, under `LC_ALL=C`, and under a non-UTC `TZ` | 901 | `SEANCE_TIERS=2 sh tests/run.sh` |
| 3 | workstation | source-as-data guards: the adapter seam, the tenant guard, config completeness both ways, verb completeness, doc liveness, the rc(8) unit, the rediscovery table | 160 | `SEANCE_TIERS=3 sh tests/run.sh` |
| 4 | workstation | the ladder against a fault-injecting mock adapter — every rung × every outcome as a truth table — plus the records, the failback guard, the fence contract, the tier-7 oracle's self-test and two real captures | 806 | `SEANCE_TIERS=4 sh tests/run.sh` |
| 5 | reaper guest | shape B: `lib/adapter.subr` against a real CBSD 15.0.9 node and a real jail, the conformance vectors against three adapters, and `docs/INSTALL.md` followed literally on a clean node | 405 | `SEANCE_TIERS=5 sh tests/run.sh` |
| 6 | reaper guest | shape A: eighteen named stages across three vnet jails — replication, interruption, promotion, quorum, concurrency, flap, failback, resurrection, hostility | 539 | `SEANCE_TIERS=6 sh tests/run.sh`, or one stage with `SEANCE_STAGES=repl` |
| 7 | reaper guest | the seeded tier: five committed seeds × 60 steps against a shadow model, five invariants diffed after every event | 6 — the oracle self-test and one per seed; each seed is 60 events and five invariants deep | `SEANCE_TIERS=7 sh tests/run.sh` — about 2 h 45 m |

Tiers 1–4 are pure sh and run on a FreeBSD workstation in seconds:

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

The four M3 stages of tier 6 run real CARP in the vnet jails: `carp` applies
what `verify --render carp` printed and reads the map back off the interfaces,
`quorum` isolates a node and requires it to freeze while its heir succeeds it,
`concurrency` tells both heirs about one death at the same instant, and `flap`
heals a link inside the debounce window and requires nothing to change. What
they cannot do is make a rule FIRE — `devd(8)` is `KEYWORD: nojail` — so they
invoke `seance promote-event` themselves and the firing is `drill-node`'s.

Tier 7 deals weighted events — ticks, kills, isolations, flaps, promotions,
double triggers, returns, failbacks, a prune racing a send, clock skew, foreign
snapshots, a replica somebody mounted by hand — against a shadow model, and
diffs five invariants after **every** event. The clock is virtual, so a trace
is a function of its seed and not of how fast the guest is.

```sh
SEANCE_TIERS=7 sh tests/run.sh                      # the committed battery
SEANCE_TIERS=7 SEANCE_SIM_STEPS=200 sh tests/run.sh  # longer traces
reaper run --profile hunt                            # fresh seeds, 6h TTL
reaper run --profile evenn                           # the same at N=4
SEANCE_SIM_DRY=1 SEANCE_SEED=42 sh tests/cluster/sim/run.sh   # no cluster
```

It runs the oracle self-test first and refuses to spend the session if the
checker cannot fire. A failing seed leaves its trace, every invocation's
captured stdout/stderr/rc, and both observed states under `$REAPER_OUT/sim/`,
and then the shrinker reduces the trace — prefix bisection first, then event-
kind removal — and prints what is left.

Two files are runnable and deliberately **not** collected by the runner,
because neither is worth paying for on every run: `tests/tier6/drill-timing.sh`
measures `drill-node`'s intervals with the shipped debounce, and
`tests/tier7/shrink-real.sh` puts the shrinker against a real failure and takes
about an hour.

And the harness's own acceptance test — revert each protection this project has
already paid for once, and require the suite to rediscover it. Run before a
milestone is trusted, never automatically:

```sh
sh tests/rediscovery/run.sh --tier 4      # workstation, seconds per row
sh tests/rediscovery/run.sh --tier 6      # reaper session, minutes per row
sh tests/rediscovery/run.sh --tier 7      # reaper session, one trace per row
```

A tier-7 row's seed and step count are part of the row and live in the table's
fifth column, not in an incantation somebody has to remember: run against a
window that never reaches the protection, a row reverts something the trace
never walks past and passes while proving nothing.

The tier-4 rows are the cheap half — promotion without fencing, stale-lineage
promotion without a threshold, the boot gate removed, the quorum rule removed,
the debounce removed, a placement file read as "no claims", a mount that did
not mount, and a verifier that masks its own crash all have to fail a
workstation test before they are allowed to fail a cluster one.

## What is here

| Path | What it is |
| --- | --- |
| `metadata.conf`, `securecmd`, `message.txt` | CBSD module markers |
| `seance` | the CBSD verb: a `cbsdsh` wrapper that exports this node's platform facts and execs the dispatcher. This is the file to link onto `PATH` |
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
| `lib/promote.subr` | the succession ladder, and `promote-event` — the devd target |
| `lib/carp.subr` | the succession map expressed as advskews, and what devd is told to do with it |
| `lib/failback.subr` | the ladder in reverse, plus the interim host's `failback-assist` half |
| `lib/gate.subr` | placement records and the resurrection gate |
| `lib/status.subr`, `lib/verify.subr` | the two reporting verbs |
| `lib/setup.subr` | `setup`'s wizard and its headless twin, and the one config-writing helper that isn't in `lib/conf.subr` |
| `drivers/fence_ipmi` | the shipped fence driver: IPMI to a BMC, credentials in their own file |
| `rc.d/seance_gate` | runs the gate before the platform's autostart |
| `etc/seance.conf.sample` | every key, documented, with its default |
| `tools/lint.sh` | `sh -n`, `shellcheck`, tiers 1–4 |
| `tests/` | the harness, the tier directories, and the committed vectors |
| `tests/tier4/ladder.tsv` | the promotion ladder's truth table: every rung × every outcome |
| `tests/drivers/fence_mock` | a fence driver that produces every answer the contract names, including the three that are not answers |
| `tests/vectors/upgrade/` | the previous release's own configuration files, so that an upgrade stays a decision |
| `docs/cbsd-module-notes.md` | what M0 learned about CBSD, with citations |
| `docs/fence-drivers.md` | the fence-driver contract, the credentials format of `drivers/fence_ipmi`, and how to write another driver |
| `docs/repl-wire.md` | the exact send/receive command lines, and the evidence for each |
| `docs/INSTALL.md` | install, upgrade, uninstall, and the cron/CARP/devd steps `verify` renders but never writes |
| `docs/DRILLS.md` | the fleet drills each milestone is gated on |
| `docs/RUNBOOK-failback.md` | what to do, in order, when a node comes back |

## Installing

`docs/INSTALL.md` is the procedure, step by step, with the CBSD source
citations behind each one, plus the upgrade and uninstall paths and the one
configuration rule that changed verdict since v0.2.0. Nothing in it is
automatic — every step is a command an operator types, and `seance verify` is
how the last one is checked. This is the shape of it:

```sh
git clone <this repo> /usr/local/cbsd/modules/seance.d
echo seance.d >> ~cbsd/etc/modules.conf
env NOINTER=1 ALWAYS_YES=1 /usr/local/cbsd/sudoexec/initenv
cbsd seance version
```

The repository root *is* the module directory, so a clone into place is a
complete installation: the platform's initialisation links the module's verb
and records it as enabled. Do **not** use `cbsd initenv inter=0` for the
unattended form — it exits 0 having done nothing, and a bare `cbsd initenv`
without a terminal never returns.

Four things the clone does not do for you, each of which `docs/INSTALL.md`
covers and each of which `seance verify` then checks:

```sh
ln -s /usr/local/cbsd/modules/seance.d/seance /usr/local/bin/seance
cp /usr/local/cbsd/modules/seance.d/rc.d/seance_gate /usr/local/etc/rc.d/
mkdir -p /usr/local/etc/cron.d
seance verify --render cron > /usr/local/etc/cron.d/seance
```

— the mesh link (the module's **verb wrapper**, never `bin/seance`), the boot
gate's rc(8) unit (disabled by default, and `service seance_gate onestart` is
how you find out it works before a reboot does), the crontab directory, which a
stock node does not have, and the crontab line itself. Once a node carries a
vhid, `verify --render carp` and `verify --render devd` are the other two, and
automatic promotion needs `auto=1` and the node's own `auto_promote` on top of
all of it — both off by default.

`docs/cbsd-module-notes.md` has the citations, the observed output, and the
other CBSD 15.0.9 defects worth knowing before relying on any of this.

## Documents

| Document | What it is |
| --- | --- |
| `DESIGN.md` | design rationale |
| `TESTING.md` | the testing contract, tier by tier |
| `HANDOFF.md` | the implementation brief |
| `docs/INSTALL.md` | install, upgrade, uninstall, and what an upgrade migrates |
| `docs/cbsd-module-notes.md` | what M0 learned about CBSD 15.0.9, with citations |
| `docs/repl-wire.md` | the exact `zfs send`/`recv` command lines, and the evidence for each |
| `docs/fence-drivers.md` | the fence-driver contract and how to write another one |
| `docs/DRILLS.md` | the fleet drills each milestone is gated on |
| `docs/RUNBOOK-failback.md` | the failback runbook, and what each refusal means |

## License

BSD-2-Clause. Copyright (c) 2026 Axonibyte Innovations, LLC.
