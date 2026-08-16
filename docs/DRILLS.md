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
| drill-guest | M2 | not yet written (M2) |
| drill-fence | M4 | not yet written (M4) |
| drill-node | M3 | not yet written (M3) |
| drill-failback | M2 | not yet written (M2) |

Only the M1 drill is written. The rest are deliberately absent: a drill for a
verb that does not exist is a procedure nobody can follow, and scope fences are
hard (charter §7).

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

   **Every line must read `none inherited... noauto`.** A `local` or `received`
   mountpoint on any of them is a drill failure and a stop-everything finding:
   it is the August defect, live, and the replica is one boot away from
   shadowing the guest's own mount.

4. **Mount the replica read-only and diff it.** This is the part that cannot be
   skipped: the point of the drill is to read the bytes. On the heir, working
   on a **clone of the snapshot**, never on the replica itself:

   ```sh
   zfs clone -o mountpoint=/mnt/drill -o readonly=on \
       <standby_root>/<home>/<guest>@seance-<home>-<TS> <pool>/drill-<guest>
   ```

   Repeat for each child dataset of the guest, cloning the same snapshot name.
   Then, on the home node, mount the *source's* snapshot of the same instant
   read-only in the same way, and diff the critical paths — the guest's config
   directory, its database directory, whatever the guest's owner names as the
   thing that must be right:

   ```sh
   diff -r /mnt/source-snap/etc /mnt/drill/etc
   ```

   Record the diff output. Empty is the pass.

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

### Evidence a passing drill leaves

- `/tmp/drill-repl-before.tsv` and `/tmp/drill-repl-after.tsv`, both from a
  `status` that exited 0.
- The step-3 property listing, before and after, identical, every line
  `none inherited noauto`.
- The step-4 diff, empty.
- A note of `TS`, the guest, the heir, and the wall-clock time the drill took
  from step 2 to step 6.

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
