# Drills

A failover system that has never eaten a real death is a liability wearing a
feature's name. Each milestone is gated on its drill passing on real hardware,
timed and logged (design §10). The harness proves mechanisms; a drill proves
the fleet.

Drills are run by an operator, on the fleet, with the estate they name. They
are not test-suite stages and nothing in `tests/` runs them. What each drill
produces — the evidence — is written down here so that "the drill passed" is a
checkable claim rather than a recollection.

| Drill | Gates | Status at v0.5.0 |
| --- | --- | --- |
| drill-replication | M1 | **documented below; fleet execution pending** |
| drill-guest | M2 | **documented below; fleet execution pending** |
| drill-failback | M2 | **the second half of drill-guest; runnable alone; fleet execution pending** |
| drill-node | M3 | **documented below; timings measured in shape A; fleet execution pending** |
| drill-fence | M4 | **documented below; `drivers/fence_ipmi` has shipped and has never powered off a machine; fleet execution pending** |

**All five are pending on a fleet, and that is the whole of what this product
has not proven.** README's status section says the same thing in the same
words: the harness proves mechanisms at tiers 1–7, and every claim about real
hardware — a real BMC, a real power cut, a real `devd(8)` rule firing on a
physical segment, a bhyve guest that has ever booted — is one of these drills
and nothing else.

Config keys `node_<key>_fence_driver` and `node_<key>_fence_target` are
already parsed, shape-checked and exercised against the mock/jail drivers from
M2 onward (`tests/tier4/t_fence_contract.sh`), and the one real driver they are
for — `drivers/fence_ipmi`, with the credentials it reads from
`docs/fence-drivers.md`'s file and never from `seance.conf` itself — shipped at
M4 and carries a 177-assertion tier-1 battery against a scripted `ipmitool`.
What none of that is, is a machine that has been powered off: that is this
drill, and it has not been run.

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

   Each line is `<dataset> <mountpoint> <source-of-mountpoint> <canmount>`,
   and the source column is MULTI-WORD: zfs prints the correct state as
   `inherited from <ancestor>`, so a line reads
   `<dataset> none inherited from <ancestor> noauto`. The pass criterion,
   column by column: mountpoint `none`, canmount `noauto` (the LAST field),
   and a source that begins `inherited from`, naming the standby root or an
   ancestor under it — do not grep for a literal `none inherited noauto`
   triple; it matches nothing and a checker built on it dies on the very
   state it wants (D-180). A `local` or `received` source is a drill failure
   and a stop-everything finding: it is the August defect, live, and the
   replica is one boot away from shadowing the guest's own mount. Save the
   listing — step 5 compares against it byte for byte.

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
  mountpoint `none`, source `inherited from <ancestor>`, canmount `noauto`.
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
- `seance placement` is runnable as the ssh user on every node (a link to the
  module's verb wrapper — the `seance` file at the module root — on that user's
  PATH; `bin/seance` is not it, see `docs/INSTALL.md` §4). Test it:
  `ssh <heir> seance placement`.
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

   What rung 4 does depends on what the fleet has configured for the home
   node, and both outcomes are a pass:

   - **no `node_<home>_fence_driver` is configured** (M2's own state — seance
     ships no driver yet): the rung stops with `notify`, saying so, and naming
     the command below. That is correct: fencing that is missing is fencing
     that cannot confirm.
   - **a driver is configured** and the node is off at the console: the rung
     may verify it and PASS, and the promotion continues without a force. Read
     what the driver said; if it says REFUSED, stop the drill — something is
     still on.

   Read the rung lines either way. Then, if it stopped, and having established
   that the node really is off — you switched it off:

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

    A node that was shut down can come back with `net.inet.carp.demotion`
    left elevated (seen every time on one fleet: 720, three interfaces'
    worth), advertising its own vhid so badly that it stays BACKUP for its
    own identity. `verify` on that node says so ("this node's OWN identity
    and it is BACKUP for it"). Record the counter before touching it -- it
    is the drill's evidence -- then bring it back to 0 with a relative
    write (`sysctl net.inet.carp.demotion=-<value>`), re-read it after the
    interfaces have settled, and never leave it negative.

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
    cat <state-dir>/succession.log        # a second record
    zfs list -H -o name,mountpoint -r <standby_root>/<home>/<guest>   # on the heir
    ```

    The second record's evidence is `failback` when nothing had to be
    discarded, and `discard:<bytes>` when step 12 refused and you accepted the
    loss — the byte count is in the record, so the decision outlives the
    terminal it was typed in. Anything else in that field is a finding.

    On the heir, the replica's datasets must be back at `mountpoint=none` and
    unmounted. A replica still mounted at CBSD's paths on the heir is the
    shadow-mount hazard, live.

14. **Use the service again**, at home.

15. **Let one more replication tick run in the normal direction**, then
    `seance verify` and `seance status` on all three nodes. Both must exit 0.

    Expect the two SURVIVING nodes to carry `WARN replica <guest>@<home>:
    the last tick exited 1` until their next tick after the home node
    returns: every pair toward it failed while it was down, and `status`
    reports the last exit of each pair. One tick on each clears it. That
    is not a drill failure; a WARN that survives the next tick is.

### Timing

Both directions are timed, the way drill-replication is: note the wall clock at
each step and record the elapsed time. The targets are for one guest of a few
hundred gigabytes on a LAN with a replica already fresh on the heir, and they
are the fleet's starting numbers rather than a specification. The two that
matter to the people who will be woken up are the OUTAGE rows — the wall clock
from the node going down to the service answering somewhere else, and the same
for the way home.

| Step | What is being timed | Target | Record |
| --- | --- | --- | --- |
| 1 | `status --tsv` + `placement` on both nodes | < 30 s | elapsed |
| 3 | the home node going down (`shutdown -p now` to no ping) | < 2 min | elapsed, and the wall clock at "no ping" |
| 4 | the first `seance promote` (the one that stops at rung 4) | < 30 s | elapsed |
| 4 | `seance promote --force=fence`, start to verdict line | < 2 min per guest | elapsed |
| **3→7** | **the outage: node down to the service answering on the heir** | **< 10 min** | **elapsed — this is the number the drill exists to produce** |
| 6 | the property listing and the two records on the heir | < 30 s | elapsed |
| 9 | `seance repl --now` on the heir, reversed direction | < 1 cadence | elapsed |
| 10–11 | the home node booting to `gate` having held the estate | < 5 min | elapsed |
| 12 | `seance failback <guest>`, start to verdict line | < 2 min + the reverse stream | elapsed, and the bytes moved |
| **12→14** | **the second outage: guest stopped on the heir to the service answering at home** | **< 10 min** | **elapsed** |
| 15 | `verify` + `status` on all three nodes | < 240 s | elapsed (each `verify` now asks every fence driver on the wire, D-186 -- measured 146 s on three nodes) |

A step that overruns its target is not by itself a failure; it is the number
the next drill is compared against, and the first one to move is the one worth
asking about. Two exceptions, both of which are findings whether or not the
drill passes: an outage row that overruns is the promise this product makes,
and a step-9 tick that does not finish inside the guest's cadence means the
next tick is queueing behind it.

### Evidence a passing drill leaves

- the before/after `status --tsv` from every node;
- the full output of both `seance promote` invocations, rung lines and all;
- both outage times from the table above, wall clock to wall clock;
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

---

## drill-node (gates M3)

**What it proves.** The real thing, and the only one of these drills that
measures the number the whole project exists to move: **detection to running,
with zero human input**. A node loses power; CARP hands its vhid to the heir;
devd fires; `promote --auto` walks the ladder; the guests are up on the
survivor. Target: **five minutes**, measured from the power going off to the
service answering.

Everything before this drill proves a mechanism. This proves the fleet.

**What it must not be.** Not an administrative shutdown — that is drill-guest,
and it is M2's. This drill cuts power, or powers the node off at the BMC
without warning it, so that the death is the one seance was designed for:
sudden, total, and with no chance for the dying node to say anything.

**Arm ONE heir relationship only** (design §12, M3). The fleet key `auto` is 1
and exactly one node's `auto_promote` names exactly one peer. Everything else
in the fleet stays notify-only, so a drill that goes wrong takes one
relationship with it and not the estate.

### Preconditions

- `seance verify` exits 0 on **every** node, with the CARP and devd checks
  among the passes — not merely the mesh ones. If any node's CARP block is
  warning, stop: the drill would be measuring the configuration and not the
  failover.
- `seance status` exits 0 on every node, and the victim's guests report fresh
  replicas on the armed heir.
- The armed heir's `seance verify` shows a `devd:` **PASS** for the victim's
  vhid. A FAIL there is precisely the arrangement this drill exists to catch,
  and catching it in `verify` costs nothing while catching it here costs an
  outage.
- A fence driver is configured for the victim and `drill-fence` has passed, or
  the operator accepts that rung 4 will stop at notify and the drill will
  measure detection only. **Say which before starting**; a drill whose scope
  was decided afterwards measures whatever happened. If a driver IS armed,
  `docs/fence-drivers.md` is what names its credentials file and what its
  `off`/`status` actions are contracted to do — read it before this drill,
  not during it.
- Somebody is at the machine, or at the PDU, or at the BMC. The power goes off
  by hand.
- A stopwatch. This drill's output is a number.

### Steps

1. **Record the starting point.** On every node:

   ```sh
   seance verify > /tmp/drill-node-verify-$( hostname -s ).txt
   seance status --tsv > /tmp/drill-node-before-$( hostname -s ).tsv
   seance placement
   ```

   Every `placement` must report zero guests hosted away from home. If one does
   not, something is already displaced and this drill would be measuring that.

2. **Record what is armed, from the configuration and not from memory.** On the
   heir:

   ```sh
   seance config | grep -E ' (auto|auto_promote) '
   seance verify --render devd
   ```

   The rendered rules must include one for the victim's vhid. Compare it
   against the installed file — `verify` already did, and this is the operator
   reading the same thing before it matters.

3. **Watch the heir.** In a second terminal on the heir, before anything is
   switched off:

   ```sh
   tail -F /var/log/messages
   ```

   `promote-event` and the detached `promote --auto` both log to syslog under
   the tag `seance`. This is where the drill is watched from; the promoted
   guests' own consoles are where it is confirmed.

4. **Note the wall clock, then cut the power.** Not `shutdown`. Pull the cord,
   or `chassis power off` at the BMC, or throw the PDU outlet. Write down the
   time to the second: **T0**.

5. **Do nothing.** This is the step. Every other drill has an operator typing a
   command; this one has an operator watching. Any keystroke on the heir before
   step 8 invalidates the measurement, and if the urge to help becomes
   irresistible that is itself the finding.

6. **Watch the sequence arrive.** In order, and each with its own time noted:

   | Mark | What it looks like | Expected |
   | --- | --- | --- |
   | T1 | `ifconfig` on the heir shows the victim's vhid as MASTER | seconds |
   | T2 | syslog: `promote-event: CARP MASTER for <victim>` | T1 + <1 s |
   | T3 | syslog: `rung 1 debounce: pass` | T2 + `debounce` (45 s by default) |
   | T4 | syslog: `rung 4 fence: pass` | T3 + fence time |
   | T5 | syslog: `promote: N of N guest(s) promoted` | T4 + mount and start |
   | T6 | the service answers | — |

   **T6 − T0 is the drill's number.** Target: under five minutes.

7. **If it stops at notify, that is a result and not a failure** — read which
   rung. Rung 2 means quorum did not form and the fleet is smaller than the
   arithmetic needs; rung 3 means the victim answered something, and the drill
   has just found a machine that is not as off as it looked; rung 4 means the
   fence could not confirm, which on a node whose power you pulled is the
   honest answer and is what `--force=fence` exists for. Record the rung, the
   time, and the wording.

8. **Verify from the disks, not from the exit code.** On the heir:

   ```sh
   seance placement
   cat <state-dir>/succession.log
   seance status
   ```

   - `placement` names every guest of the victim's estate and its home;
   - each `succession.log` record carries `fence:<driver>` — **not**
     `force:<somebody>`. There was no human, so a `force:` record here means
     the run was not the one the drill thought it was;
   - `status` reports the guests running here.

9. **Confirm exactly one survivor acted.** On the *other* peer:

   ```sh
   seance placement
   ```

   It must claim nothing. The second heir standing down is what "exactly one
   survivor acts" means, and it is read from that node's own records rather
   than from the order two commands finished in.

10. **Bring the victim back and let the gate run.** Do not start anything by
    hand. Then, on the victim:

    ```sh
    seance gate --check
    seance status
    ```

    Its estate must be **held**. This is drill-guest's step 11 again, and it is
    repeated here because the gate has now been reached by a path no human
    chose.

11. **Fail back**, exactly as `docs/RUNBOOK-failback.md` describes, and record
    whether the `written@<base>` guard refused.

12. **Disarm, or do not — but write down which.** If the fleet stays armed
    after the drill, `seance verify` on every node is the evidence that it is
    armed correctly. If it is disarmed, say so, because the next person to read
    `auto=0` will otherwise assume it was never on.

### Timing

| Step | What is being timed | Target | Record |
| --- | --- | --- | --- |
| 4→T1 | power off to the heir holding the vhid | < 10 s | elapsed |
| T1→T2 | CARP transition to `promote-event` | < 2 s | elapsed |
| T2→T3 | the debounce, which is configuration and not performance | `debounce` | elapsed, and the configured value |
| T3→T4 | quorum, probes and the fence | < 90 s | elapsed |
| T4→T5 | mount, register and start, per guest | operator's call | elapsed, and the guest count |
| T5→T6 | the guest booting to a service that answers | the guest's own | elapsed |
| **T0→T6** | **detection to running** | **< 5 min** | **elapsed** |

The debounce is the one row that is a decision rather than a measurement:
45 seconds of the budget is spent on purpose, buying immunity to a flapping
link. If T0→T6 misses the target by less than the debounce, the finding is
about the debounce and not about seance.

#### Measured, so that the targets above are not guesses

Nobody has run this drill on hardware yet, and the numbers a drill is judged
against should not be estimates. `tests/tier6/drill-timing.sh` runs the same
sequence in the pseudo-cluster — the same seance, the same configuration, the
shipped `debounce` of 45 s rather than a fixture's — and reports what each
interval cost. Measured on 2026-08-19, in the reaper guest
(`freebsd-15.1`, three vnet jails, and the pseudo-cluster's own jail fence
driver):

| Interval | Measured | The target above |
| --- | --- | --- |
| T0→T1 victim gone to the heir holding its vhid | 64 s | < 10 s |
| T1→T2 `promote-event` returns, devd's loop released | 0 s | < 2 s |
| T2→T5 debounce, quorum, probes, fence, mount, register, start | 60 s | ~ 90 s + debounce |
| **T0→T5** | **124 s** | **< 5 min** |

Read those three limits with the numbers, because a measurement quoted without
them is a measurement misquoted:

- **T0→T1 is the fixture's, not CARP's.** Shape A's "power cut" stops the
  victim's jail through `tests/cluster/lib/cluster.subr`, which unmounts its
  delegated dataset and waits for a vnet jail to die before the vhid can be
  taken over; on hardware the
  advertisement simply stops and the heir preempts within three advertisement
  intervals. The 64 s is an upper bound with a fixture in it, and the drill's
  < 10 s target is the one to measure against real power.
- **T1→T2 is measured without devd**, which is `KEYWORD: nojail` and does not
  run in a vnet jail (D-128): the script invokes `promote-event` itself, as
  every tier-6 stage does. What is measured is the verb, which is the half
  seance owns — it returned inside the second it was called in, with the
  ladder detached behind it.
- **T5→T6 is not measured at all.** The pseudo-cluster's guests are records
  rather than processes, so "the service answers" has no meaning there. On
  hardware it is the guest's own boot time and it is the operator's to budget.

The useful part is what is left when those three are set aside: everything
seance does between hearing about a death and having the estate running cost
**60 seconds**, of which **45 were the debounce spent on purpose**. The
five-minute target is not tight for seance; it is tight for the guests.

### Evidence a passing drill leaves

- the before/after `status --tsv` and `verify` output from every node;
- the syslog extract from the heir, from T2 to T5, whole and unedited;
- the `succession.log` records, every one carrying `fence:<driver>`;
- the other peer's `placement`, empty;
- the timing table above filled in, including T0→T6;
- the `seance version` of every node, so a later drill compares against the
  code this one ran.

### What a failure means

- **T1 never arrives** — CARP did not transition. The vhid is not really
  running on the heir, or the advskews do not encode the map. `seance verify`
  on the heir says which; if it said PASS beforehand, the finding is in the
  check and outranks the drill.
- **T1 arrives and T2 does not** — devd is not acting on it. Either the rule is
  not installed where devd reads, or devd is not running, or the action names a
  path that is not there. All three are things `verify` checks; a green
  `verify` and a missing T2 is a defect in the check.
- **T2 arrives and says automation is not armed** — the rule fired and the
  configuration disagreed with it. Read both. This is the exact case rung 0
  exists for, and it means the drill was set up wrong rather than that seance
  is.
- **T3 never arrives** — the debounce re-check found this node no longer MASTER.
  The link flapped, or the victim is not as dead as the power switch suggests.
  Look at the victim before anything else.
- **Two nodes promoted** — stop everything. This is the split brain the product
  exists to prevent and it outranks every other result in this file. Keep both
  nodes' `succession.log`, both `placement` files, and the syslog from both.
- **T0→T6 misses five minutes** — read the timing table for which interval
  swallowed it. A slow fence and a slow guest boot are different findings and
  only one of them is seance's.

---

## drill-fence (gates M4)

**What it proves.** That the real fence driver — `drivers/fence_ipmi` against
a real iDRAC/BMC, credentials and endpoint named in `docs/fence-drivers.md` —
powers a target off and VERIFIES it off inside `fence_timeout`
(`etc/seance.conf.sample`, default 60s), and that `seance promote`'s rung 4
(`promote_rung_fence` in `lib/promote.subr`) reads that result correctly.
Rung 4 is the rung the whole ladder's split-brain guarantee rests on
(design §7): "command accepted" is not "off", and this is the drill that
proves the driver knows the difference before it is ever asked to know it
about a node that might answer back.

**What it must not do.** This drill fences a node that is **powered on and
idle**, not a dead one — proving the fence path is this drill's whole job,
proving a real failover is `drill-node`'s. No guest here is administratively
at risk the way `drill-guest`'s is, but the target node itself goes dark for
real: schedule the window like a real outage, because for `fence_timeout`
seconds and however long it takes to power it back on, it is one.

**Preconditions.**

- `docs/fence-drivers.md` has been read for the driver under test — where its
  credentials live (never in `seance.conf` itself: `node_<key>_fence_driver`
  and `node_<key>_fence_target` name the driver and an entry, and the entry's
  host, user and passfile live in the driver's own lookup file), and what
  `off` and `status` are contracted to do (handoff §2.4): `off` exits 0 only
  on VERIFIED off, bounded by `fence_timeout`; `status` distinguishes off
  (exit 0), on (exit 1) and cannot-determine (exit 2).
- `seance config --check` passes with the target's `fence_driver` and
  `fence_target` set — shape-checked already by `_conf_check_node`
  (`lib/conf.subr`) before this drill ever touches the network.
- The driver executable is where `promote_fence_exe` (`lib/promote.subr`)
  looks: `drivers/fence_<driver>` in the module directory, or on `PATH`.
- The target is reachable, powered on, and doing nothing that matters for the
  drill's duration.
- A second way to power the target back on that does **not** depend on the
  fence driver working — console access, a PDU, a second admin. A drill that
  can only recover through the thing it is testing is not a drill.

### Steps

1. **Read status first, by hand, before seance touches anything.**

   ```sh
   drivers/fence_ipmi status <target>
   ```

   Exit 1 (ON) is the expected precondition. Exit 0 (already off) means
   somebody got there first and this drill would measure the wrong thing —
   stop and find out who. Exit 2 (cannot determine) means fix that before
   anything else: a driver that cannot determine status now will not suddenly
   manage it during a real death.

2. **Fence it, timed.**

   ```sh
   time drivers/fence_ipmi off <target>
   ```

   Record the wall-clock time and the exit code. `off` exits 0 **only** on
   verified off; record what it printed either way. Compare the elapsed time
   against the configured `fence_timeout` — a driver that verifies but takes
   longer than the timeout is a driver `promote`'s own rung 4 will read as
   CANNOT DETERMINE on a real run, which is a finding worth having now rather
   than mid-outage.

3. **Confirm from a second source.** Whatever `status` you would trust that
   is not the driver itself — console, PDU, physically being in the room —
   and the driver's own `status` again:

   ```sh
   drivers/fence_ipmi status <target>
   ```

   Both must agree: OFF. A disagreement here outranks everything else in this
   drill — see "what a failure means" below.

4. **Drive it through the ladder, not just the driver.** On a survivor, with
   the target still off, decide BEFORE running this whether the target's
   guests are ones this drill is prepared to move — the ladder does not pause
   for confirmation once started:

   ```sh
   seance promote <target> --guest <guest>
   ```

   Rung 3 (probes) should report no answer from the target; rung 4 (fence)
   should PASS, naming the driver, and the promotion should proceed on the
   real path `promote_rung_fence` takes — not the mock's. Read every rung
   line, the way `drill-guest` does.

5. **Power the target back on**, by the recovery path from the preconditions,
   never by asking the fence driver to reverse itself. No driver in this
   contract has an `on` action, and that is deliberate (handoff §2.4): a fence
   driver that could also power a node ON would be a second way to create the
   exact split brain fencing exists to prevent.

6. **Verify the fleet again.**

   ```sh
   seance verify
   seance status
   ```

   Both must exit 0 once the target is back and gated
   (`docs/RUNBOOK-failback.md`), and once whatever `promote` moved in step 4
   has been failed back.

### Timing

| Step | What is being timed | Target | Record |
| --- | --- | --- | --- |
| 1 | `status` before touching anything | < 10 s | elapsed |
| 2 | `off`, start to verified | < the configured `fence_timeout` | elapsed, and `fence_timeout` itself |
| 3 | the second-source confirmation | operator's call | elapsed |
| 4 | `seance promote` through rung 4 | < 90 s | elapsed, and which rung it reached |
| 6 | `verify` + `status` once the target is back | < 60 s | elapsed |

A step that overruns its target is the number the next drill is compared
against, except step 2: an `off` that verifies past `fence_timeout` is not a
slow drill, it is a driver that will read as CANNOT DETERMINE on a real
promotion, and the finding is the timeout or the network path, not the drill.

### Evidence a passing drill leaves

- the driver's own `status` output, before and after, alongside the
  second-source confirmation that agrees with it;
- `off`'s wall-clock time against the configured `fence_timeout`;
- the `seance promote` rung lines through rung 4, whole and unedited;
- `verify` and `status` output from before the drill and after recovery, both
  exit 0;
- the `seance version` of the node the drill was run from, so a later drill
  compares against the code this one ran.

### What a failure means

- **`off` exits 0 but the second source disagrees** — the driver is lying
  about verification, which is worse than a driver that times out: rung 4
  would PASS a promotion the fence never actually delivered. Stop using this
  driver until this is understood; nothing else in this file matters until it
  is, and no other row in this table outranks it.
- **`off` never returns inside `fence_timeout`** — a real `promote` run
  against this node reads this as CANNOT DETERMINE and stops at notify, not
  FAIL; that is correct fail-safe behaviour, but a fleet that expects
  automatic fencing here has an arrangement that does not match reality. Fix
  the timeout or the network path before arming `auto` anywhere that depends
  on it.
- **Rung 3 (probes) reports the target answering** while the driver says
  OFF — believe the probe, not the driver, and investigate before running
  this drill again.
- **Rung 4 reports REFUSED or STILL ON** — the ladder did exactly what it
  should. This is not a drill failure; it is the drill working, and the
  question becomes why the driver's own `off` disagreed with `promote`'s own
  check moments later.
