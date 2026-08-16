# Runbook: a node has come back

*First version, M2. Written for the person reading it at 03:00 with a node
half-way through booting. Read the whole page before typing anything on the
returning node; there is exactly one order that is safe and it is not the
obvious one.*

---

## The one sentence

**A returning node must not start anything until a living peer has said it is
not already running elsewhere.** Everything below is that sentence, in order.

## Before anything: what state is the fleet in?

On any node that stayed up:

```sh
seance status
seance placement
```

`placement` prints one record per guest that node is hosting **away from
home**. Those are the guests that were promoted while the other node was down.
If it prints nothing, nothing was promoted, and the returning node has nothing
to fail back — skip to *[The node was down but nothing moved](#the-node-was-down-but-nothing-moved)*.

Also read the succession log on the node that did the promoting:

```sh
cat <state-dir>/succession.log
```

One TSV record per promotion: guest, old home, new home, UTC timestamp, and the
**evidence** — `fence:<driver>` if a fence driver verified the old home was
off, or `force:<operator>` if a human said so. If the evidence is a `force:`,
somebody made a judgement call; it is worth knowing whose before you undo it.

## Step 1 — the returning node must be gated

The gate runs from `rc.d/seance_gate`, before the platform's autostart. It asks
every living peer who is holding what, and:

- **a peer claims one of this node's guests** → that guest is withheld;
- **not one peer answers** → the **whole estate** is withheld.

Confirm it happened:

```sh
seance gate --check          # what it would withhold now; changes nothing
seance status                # every displaced guest should read held yes
```

**If a guest is running here and a peer also claims it, you have a split
brain.** Stop the local copy immediately — do not wait to finish reading this
page — and then work out how it started. That is the failure mode the whole
product exists to prevent, and it is worth the interrupt.

**If the gate did not run at all** (the unit is not enabled, or the node was
started by hand), hold the estate now:

```sh
service seance_gate onestart
```

and find out why it did not run before the next reboot.

## Step 2 — decide, per guest, whether to bring it home

There is no rule that says a guest must come home immediately. A guest running
happily on its heir is a guest that is running. Failback is a second planned
outage of that guest, and it should be taken when someone is watching.

What failback needs, on the origin (the guest's home node):

- the guest is **registered here** — failback returns a guest to a home that
  still knows about it; it is not a second promotion;
- the guest is **held or stopped here** — failback overwrites this node's copy,
  and it will not do that underneath a running guest;
- the interim host is **reachable** and still claims the guest.

## Step 3 — fail back, one guest at a time

On the origin:

```sh
seance failback <guest>
```

What it does, in order, printing the undo beside each step:

1. stops the guest on the interim host;
2. takes a final snapshot there;
3. **measures** what has been written to this node's copy since the incremental
   base, and either proceeds or refuses (see below);
4. pulls the reverse incremental into this node's **live** dataset;
5. unregisters and unmounts the guest on the interim, putting its replica
   datasets back to `mountpoint=none`;
6. releases the guest here and starts it;
7. clears the interim's claim and appends a `failback` succession record;
8. prunes the interim's lineage from this node's datasets;
9. says which heirs the next replication tick will send to.

### If it refuses with a byte count

```
failback: REFUSED -- 1441792 byte(s) have been written here to the copy of web01
        since the base the reverse stream would roll back to.
```

This is the design working, not failing. The reverse stream lands with
`zfs recv -F`, which rolls this node's dataset back to the base before rolling
it forward — and those bytes are what the rollback destroys. They exist because
this node wrote to the guest's dataset after its last successful replication:
the crash itself, a partial boot, a filesystem replay, or somebody poking about.

**Look at them before you discard them.** A clone of the base snapshot, mounted
read-only, is the cheapest way:

```sh
zfs clone -o mountpoint=/mnt/before -o readonly=on <dataset>@<base> <pool>/inspect
# ... and compare with the live dataset ...
zfs destroy <pool>/inspect
```

If they are debris, discard them deliberately and on the record:

```sh
seance failback <guest> --discard-origin-writes
```

The byte count is written into the succession record as `discard:<bytes>`, so
the decision outlives the terminal it was typed in.

If they are **data** — something wrote to this node's copy that you cannot
lose — stop. Do not discard. Copy what you need out of the live dataset first;
then failback with the flag. seance cannot merge two divergent copies and will
not pretend to.

**The refusal usually costs nothing.** seance measures before it stops
anything, so a refused failback normally leaves the guest running on the
interim host. The exception is a fleet with no `standby_root` configured, where
the measurement cannot be made until after the final snapshot — there the guest
has already been stopped, and the refusal says so and names the way back:

```sh
ssh <interim> seance failback-assist <guest> start
```

### If it refuses because no peer claims the guest

```
failback: FAIL (no living peer claims <guest>).
```

Two very different things look like this, and it is worth telling them apart:

- the guest is **already home** — check `seance status` here;
- the peer that holds it **is not answering** — check `seance placement
  --remote` and the mesh. A failback from a peer that cannot be reached is not
  a failback, and seance will not fabricate one.

## Step 4 — release anything still held that should not be

After a failback, the guest is released automatically. A guest that is still
held after every relevant failback — because it was held by the "not one peer
answered" fail-safe, for instance — is released explicitly:

```sh
seance placement --remote      # confirm nobody claims it
seance gate --release <guest>
```

`--release` refuses while any peer still claims the guest, **and while any
living peer could not report its placement at all**. The second refusal names
the peer: it is up, its seance could not answer, and nothing here can tell a
node with no claim from a node that never got to state one. Fix seance there —
`ssh <peer> seance placement` is the test — and try again. The same silence
freezes `promote` and `failback` for the same reason.

`--release` refuses while any peer still claims the guest, and refuses while no
peer answers at all. Both refusals are the gate doing its job; neither is
something to work around.

## Step 5 — prove the fleet is back

On every node:

```sh
seance verify
seance status
```

Both must exit 0. Then wait for one replication tick and read `status` again:
the guest's replicas must be **fresh** on its heirs, in the normal direction,
with `@seance-<home>-*` names.

Finally, read the succession log once more. A completed round trip leaves two
records for the guest: the promotion, and the failback.

---

## The node was down but nothing moved

If no peer claims anything, no promotion happened: the node died, its guests
were down, and nobody inherited them. The gate will have withheld nothing, and
the estate will have autostarted normally. Confirm with `seance status` and
`seance placement` on every node, and check `seance verify` for whatever caused
the outage in the first place.

## Things that are never the answer

- **Starting a guest by hand on a returning node** because "the gate is being
  awkward". The gate is the only thing standing between you and two writers.
- **Running `seance promote` on the returning node** to take its own guests
  back. Promotion moves a guest away from a dead node; failback moves it home.
  They are not symmetric and using one for the other will not do what you want.
- **`--discard-origin-writes` as a habit.** It exists so that a deliberate
  decision can be recorded. A flag that is always passed records nothing.
- **Editing `placement` or `succession.log` by hand.** `succession.log` is
  append-only and is the account of what happened; `placement` is what every
  other node reads to decide whether to act. If either is wrong, find out why
  before rewriting it, and write down what you did.

## Mesh prerequisites this runbook assumes

- `seance placement` runs as the ssh user on every node — a link to
  `bin/seance` somewhere on that user's `PATH`. The platform's own `PATH`
  belongs to its shell, not to an ssh session, so this is a deliberate step at
  install time. `ssh <peer> seance placement` is the test.
- The configuration file is byte-identical on every node. `seance verify` says
  so loudly when it is not; seance never copies it.
- Clocks are in rough sync. `seance verify` measures the pairwise delta.
