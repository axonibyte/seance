# Drills

A failover system that has never eaten a real death is a liability wearing a
feature's name. Each milestone is gated on its drill passing on real hardware,
timed and logged (design §10). The harness proves mechanisms; a drill proves
the fleet.

Drills are run by an operator, on the fleet, with the estate they name. They
are not test-suite stages and nothing in `tests/` runs them. What each drill
produces — the evidence — is written down here so that "the drill passed" is a
checkable claim rather than a recollection.

| Drill | Gates | Status |
| --- | --- | --- |
| drill-replication | M1 | **documented below; fleet execution pending** |
| drill-guest | M2 | **documented below; fleet execution pending** |
| drill-failback | M2 | **the second half of drill-guest; runnable alone** |
| drill-fence | M4 | not yet written (M4) |
| drill-node | M3 | not yet written (M3) |

The M3 and M4 drills are deliberately absent: a drill for a verb that does not
exist is a procedure nobody can follow, and scope fences are hard (charter §7).

---

## drill-replication (gates M1)

**What it proves.** That a replica on a peer is a faithful, mountable, complete
copy of the guest's data at a known instant — verified by reading it, not by
believing the exit code of the thing that wrote it. And that seance's own
reporting agrees with the disks.

**What it must not do.** It must not stop a guest, must not touch the live
dataset, and must not leave a mountpoint set on any standby dataset. Everything
below is read-only with respect to the running estate.

**Preconditions.**

- `seance verify` exits 0 on every node.
- `seance status` exits 0 on every node.
- The crontab line `seance verify --render cron` prints is installed and cron
  has run it at least twice (check the lag records' tick epochs move).

### Steps

1. **Record the starting point.** On the guest's home node:

   ```sh
   seance status --tsv > /tmp/drill-repl-before.tsv
   seance verify > /tmp/drill-repl-verify.txt
   ```

   Keep both. They are the evidence that the fleet was healthy *before* the
   drill, which is what makes a failure during it mean something.

2. **Take a tick you can name.** On the home node:

   ```sh
   seance repl --guest <guest> --now
   ```

   Note the verdict line. Then read the newest snapshot the peer has
   acknowledged:

   ```sh
   awk '{ print $1 }' <state-dir>/lag/<guest>.<heir>
   ```

   Call it `TS`. Every step below is about that exact snapshot.

3. **Verify the shadow-mount law on the peer, before touching anything.** On
   the heir:

   ```sh
   zfs list -H -o name -t filesystem,volume -r <standby_root>/<home>/<guest> |
   while read -r d; do
       printf '%s %s %s %s\n' "$d" \
           "$( zfs get -H -o value  mountpoint "$d" )" \
           "$( zfs get -H -o source mountpoint "$d" )" \
           "$( zfs get -H -o value  canmount   "$d" )"
   done
   ```

   Each line is `<dataset> <mountpoint> <source-of-mountpoint> <canmount>`, and
   **every one of them must read `none inherited noauto`** after the dataset
   name. A `local` or `received` in the third column is a drill failure and a
   stop-everything finding: it is the August defect, live, and the replica is
   one boot away from shadowing the guest's own mount. Save the listing —
   step 5 compares against it byte for byte.

4. **Mount the replica read-only and diff it.** This is the part that cannot be
   skipped: the point of the drill is to read the bytes. On the heir, working
   on a **clone of the snapshot**, never on the replica itself:

   ```sh
   zfs clone -o mountpoint=/mnt/drill -o readonly=on \
       <standby_root>/<home>/<guest>@seance-<home>-<TS> <pool>/drill-<guest>
   ```

   Repeat for each child dataset of the guest, cloning the **same snapshot
   name** and giving each clone the mountpoint that puts it back where it
   belongs under `/mnt/drill` — a child whose tail below the guest root is
   `data` gets `-o mountpoint=/mnt/drill/data`. A clone that inherits its
   parent's mountpoint lands on top of it and the diff below then compares a
   directory with itself.

   Then, on the home node, clone the *source's* snapshot of the same instant in
   the same way (`-o mountpoint=/mnt/source-snap -o readonly=on`) and diff the
   critical paths — the guest's config directory, its database directory,
   whatever the guest's owner names as the thing that must be right:

   ```sh
   diff -r /mnt/source-snap/etc /mnt/drill/etc
   ```

   Record the diff output. Empty is the pass. The two ends are different
   machines, so run the diff where both are visible — either copy one side
   over, or run `diff` across `ssh` — and record which you did.

5. **Undo, and prove you did.**

   ```sh
   zfs destroy <pool>/drill-<guest>          # the clone, and every child clone
   ```

   Then repeat step 3. The properties must read exactly as they did before —
   the clone must have left no mountpoint behind on the replica.

6. **Re-run the reporting.**

   ```sh
   seance status --tsv > /tmp/drill-repl-after.tsv
   seance verify
   ```

   `status` must still exit 0, and the replica's timestamp for that guest must
   be `TS` or newer. `verify` must still exit 0.

### Timing

Drills are gates and gates are timed (design §10). Note the wall clock at the
start of each step and record the elapsed time; the targets below are for one
guest of a few hundred gigabytes on a LAN, and are a starting point for the
fleet's own numbers rather than a specification.

| Step | What is being timed | Target | Record |
| --- | --- | --- | --- |
| 1 | `status --tsv` + `verify` on the home node | < 30 s | elapsed |
| 2 | `seance repl --guest <guest> --now` | < 1 cadence | elapsed, and `TS` |
| 3 | the property listing on the heir | < 10 s | elapsed |
| 4 | clone, mount and `diff -r` of the critical paths | operator's call | elapsed, and how much was diffed |
| 5 | destroy the clones, re-read the properties | < 30 s | elapsed |
| 6 | `status --tsv` + `verify` again | < 30 s | elapsed |
| 2→6 | the whole drill | — | elapsed |

A step that overruns its target is not by itself a failure — it is the number
the next drill is compared against, and the first one to move is the one worth
asking about. Step 2 is the exception: a tick that does not finish inside the
guest's cadence means the next tick is queueing behind it, which is a finding
whether or not the drill passes.

### Evidence a passing drill leaves

- `/tmp/drill-repl-before.tsv` and `/tmp/drill-repl-after.tsv`, both from a
  `status` that exited 0.
- The step-3 property listing, before and after, identical, every line
  `none inherited noauto`.
- The step-4 diff, empty.
- A note of `TS`, the guest, the heir, and the timing table above filled in,
  including the step 2→6 total.
- The `seance version` of the node the drill was run from, so that a later
  drill can be compared against the code this one exercised.

### What a failure means

- **Step 3 fails** — a replica dataset carries its own mountpoint. Stop. Do not
  reboot the heir. `seance repl` will repair the property on its next tick and
  log it at `warning`; find out how it got there before trusting the repair,
  because something wrote it.
- **Step 4 fails** — the replica's bytes are not the source's. This is the
  finding the whole project exists to catch early. Keep the clone, keep the
  diff, and do not prune: the lineage in evidence is worth more than the disk
  space.
- **Step 5 fails** — the clone left state behind. The undo is incomplete, and
  every future drill inherits it.
- **Step 6 fails** — the drill changed the fleet's health. Read `verify`'s
  output; the check that flipped names the thing that changed.

---

## drill-guest (gates M2, both directions)

**What it proves.** That a guest whose home node has been *administratively*
killed comes back on its heir — mounted in place, registered, running, with its
succession recorded — and then goes home again, with the interim host's writes
carried back and the origin's crash-window writes accounted for rather than
silently destroyed.

No fencing hardware is involved and no power is cut. The home node is stopped
by hand, which is exactly the situation `--force=fence` exists for; the drill
therefore also exercises the operator's half of the ladder.

**Choose a guest whose loss you can survive.** This drill stops a guest, moves
it, and moves it back. It is not a read-only drill and there is no version of
it that is.

**Preconditions.**

- `seance verify` and `seance status` both exit 0 on every node.
- The guest has been replicating for long enough that `status` reports its
  replica **fresh** on the heir. Note the heir; call it `<heir>`.
- The heir has room: the guest's estate fits, and `zfs list` on the heir says
  so rather than somebody's memory.
- `seance placement` is runnable as the ssh user on every node (a link to
  `bin/seance` on that user's PATH). Test it: `ssh <heir> seance placement`.
- `rc.d/seance_gate` is installed and `seance_gate_enable="YES"` on the home
  node. Confirm with `service seance_gate status` or by reading rc.conf; a
  drill that skips the gate is not testing the half that matters most.

### Direction one: promotion

1. **Record the starting point.** On the home node and on the heir:

   ```sh
   seance status --tsv > /tmp/drill-guest-before-$( hostname -s ).tsv
   seance placement
   ```

   Both `placement` outputs should report 0 guests hosted away from home. If
   either does not, stop: something is already displaced and this drill would
   be measuring that instead.

2. **Note what you are about to lose.** On the home node:

   ```sh
   awk '{ print $1 }' <state-dir>/lag/<guest>.<heir>
   ```

   Call it `TS`. Everything the guest writes after `TS` is what the promotion
   will cost, and step 8 checks that the number seance prints agrees.

3. **Kill the home node administratively.** Stop its guests, then stop the
   node — power it off from the console, or `shutdown -p now`. Do **not** cut
   power at the PDU: that is drill-node, and it is M3's.

4. **Walk the ladder on the heir.**

   ```sh
   seance promote <home> --guest <guest>
   ```

   It will stop at rung 4 with `notify`, because no fence driver can confirm a
   node somebody switched off by hand. That is correct. Read the rung lines.
   Then, having established that the node really is off — you switched it off:

   ```sh
   seance promote <home> --guest <guest> --force=fence
   ```

5. **Read every rung line.** Not the exit code: the lines. Rung 2 must report
   the quorum it formed and name the peers it reached. Rung 3 must report that
   the home node answered neither ping nor ssh — if it says anything else, stop
   the drill and find out what is still up. Rung 4 must say `forced` and name
   you. Rung 5 must name the guest and its newest replica. Rung 6 must print,
   for every dataset it touched, the undo line beside it.

6. **Verify from the disks, not from the exit code.** On the heir:

   ```sh
   zfs list -H -o name,mountpoint,canmount -r <standby_root>/<home>/<guest>
   seance placement
   cat <state-dir>/succession.log
   ```

   - every filesystem of the guest is mounted at the path the platform expects
     (`<jaildatadir>/<guest>-data` for a jail, `<workdir>/vm/<guest>` for a VM),
     and `canmount` is still `noauto` — the mounts are explicit, by design;
   - `placement` names the guest and its home;
   - `succession.log` has one TSV record: guest, old home, new home, UTC
     timestamp, and `force:<you>` as the evidence.

7. **Verify the guest is actually running**, by using it — connect to the
   service it exists to provide. `seance status` reporting `running yes` is the
   claim; the service answering is the proof.

8. **Check the RPO seance printed** against `TS` from step 2. They must
   describe the same instant. A disagreement here is a bug in the reporting and
   is worth more than the rest of the drill.

9. **Confirm the direction reversed.** Wait one cadence, then on the heir:

   ```sh
   seance repl --now
   seance status --tsv
   ```

   The heir now snapshots the guest as `@seance-<heir>-*` and sends to its own
   heirs. The pair pointing at the dead home node is expected to fail and to be
   logged as failed — that is not a drill failure.

### Direction two: failback (this is drill-failback)

10. **Bring the home node back**, and let the gate run. Do not start anything
    by hand.

11. **Prove the gate withheld the estate.** On the home node:

    ```sh
    seance gate --check
    seance status
    ```

    The guest must be reported **held**. If it came up running, the drill has
    just found a split brain — stop the guest immediately, and treat the gate
    as broken until you know why.

12. **Fail back.** On the home node:

    ```sh
    seance failback <guest>
    ```

    Expect one of two outcomes, and both are a pass:

    - it completes, and the guest is home, released and running;
    - it **refuses**, printing a byte count of what was written to the home
      node's copy since the incremental base. That is the crash window, made
      explicit. Look at what those bytes are. If they are debris — a partial
      boot, a log line, a crash dump — run
      `seance failback <guest> --discard-origin-writes` and record the byte
      count in the drill log. If they are *data*, stop: the drill has found
      something more interesting than a drill.

13. **Verify, again from the disks.**

    ```sh
    seance placement                      # on the home node: 0 guests away
    ssh <heir> seance placement           # and on the heir: the claim is gone
    cat <state-dir>/succession.log        # a second record, evidence 'failback'
    zfs list -H -o name,mountpoint -r <standby_root>/<home>/<guest>   # on the heir
    ```

    On the heir, the replica's datasets must be back at `mountpoint=none` and
    unmounted. A replica still mounted at CBSD's paths on the heir is the
    shadow-mount hazard, live.

14. **Use the service again**, at home.

15. **Let one more replication tick run in the normal direction**, then
    `seance verify` and `seance status` on all three nodes. Both must exit 0.

### Evidence a passing drill leaves

- the before/after `status --tsv` from every node;
- the full output of both `seance promote` invocations, rung lines and all;
- the `succession.log` records from both directions, and the `placement` files
  before, between and after;
- the wall-clock time from step 3 (node down) to step 7 (service answering);
- if step 12 refused: the byte count, what those bytes were, and the decision;
- the step 13 property listing from the heir, every replica dataset
  `mountpoint=none` and unmounted.

### What a failure means

- **Rung 3 reports the home node answering** — it is not dead. Stop. Everything
  after this rung would have been a split brain, and the rung did its job.
- **Rung 4 reports refused rather than notify** — a fence driver is configured
  and said the node is still on. Believe it before you believe the console.
- **Step 6 finds a dataset with `canmount=on` or a mountpoint it did not set**
  — the ceremony is wrong, or something else has been in the standby tree.
- **Step 11 finds the guest running at home** — the gate did not run, or did
  not hold. This is the defect the boot gate exists for and it outranks the
  rest of the drill.
- **Step 12 refuses and the bytes are data** — the crash window ate a write
  that mattered. Keep both copies. This is a design conversation, not a bug
  report.
- **Step 13 finds the heir's replica still mounted** — `failback-assist
  unregister` did not finish. The heir is one reboot away from mounting a
  replica over nothing; fix it before the next tick.
