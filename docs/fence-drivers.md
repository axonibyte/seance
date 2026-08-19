# Fence drivers

Detection cannot tell a dead node from an isolated one. Fencing can: a node
that has been powered off is not writing to anything, whatever the network
thinks. Fencing is therefore the rung of the promotion ladder (DESIGN.md §7)
that turns "probably dead" into "cannot possibly be writing", and everything
downstream of it — mounting replicas, registering guests, starting them — is
safe only because that rung ran and was believed.

This document is the contract a fence driver must satisfy, the credentials
format of the shipped `fence_ipmi`, and what it takes to write another one.

One driver ships. The door is open a crack for others; there is no plugin ABI,
no registration, no callbacks. A driver is an executable with a fixed
command line and fixed exit codes, and that is the whole interface.

---

## 1. The contract

    fence_<driver> off    <target> [--config <file>] [--timeout <seconds>]
    fence_<driver> status <target> [--config <file>] [--timeout <seconds>]
    fence_<driver> --help

`<target>` is the value of the site config key `node_<key>_fence_target`, and
`<driver>` is the value of `node_<key>_fence_driver`. Both are per-node config
(`etc/seance.conf.sample`); the driver never reads `seance.conf` itself.

### Exit codes (HANDOFF.md §2.4, decision D-44 item 2)

| action   | 0                  | 1                          | 2                 |
|----------|--------------------|----------------------------|-------------------|
| `off`    | verified powered off | refused, or still on when the budget expired | cannot determine |
| `status` | off                | on                          | unknown           |

Three things about that table are load-bearing, and a driver that gets any of
them wrong is worse than no driver at all:

- **`off` exits 0 only on verified off.** "Command accepted" is not "off".
  Issue the power-off, then *read the power state back* until it says off or
  the budget is spent.
- **1 is a hard abort and is never forceable** (decision D-44 item 1). A fence
  that was refused, or a machine whose power still reads on, is precisely the
  situation in which a forced promotion produces two writers. seance pages a
  human and stops.
- **2 means "I could not find out".** The ladder stops at notify, and a human
  who has looked at the facility may run `seance promote <node> --force`. Use
  it for an unreachable endpoint, an authentication failure, unparsable
  output, and for the special case below.

**Empty stdout with exit 0 is a contract violation and must be treated as 2.**
A tool that succeeds and says nothing has not answered the question. (The same
rule governs the CBSD adapter — HANDOFF.md §2.3.)

### I/O discipline

- **stdout is the verdict, and is one line:**

      fence_<driver>: <target> <off|on|unknown|refused> <detail>

  Every path prints exactly one, including usage errors. `--help` is the only
  exception: it prints usage and fenced nothing, so it has no verdict.
- **stderr is diagnostics** — what was tried, what came back, what to fix.
  The caller logs it; nothing downstream parses it.
- **Never print a credential.** If a diagnostic echoes the command line, the
  password argument is shown redacted.

### Bounding

Every call to an external tool is bounded by `timeout(1)` (FreeBSD base since
10.3; exit status 124 means the limit was reached). `--timeout` is the budget
for the whole action; it defaults to the environment variable
`SEANCE_FENCE_TIMEOUT`, and failing that to 60 seconds, which matches the fleet
config key `fence_timeout`. A BMC that accepts a TCP connection and then says
nothing must not be able to hold a promotion open indefinitely.

---

## 2. `fence_ipmi` — the shipped driver

`drivers/fence_ipmi` fences over IPMI-over-LAN using `ipmitool(1)`, which is a
documented dependency (`sysutils/ipmitool`; DESIGN.md §11). It sources nothing
from `lib/`: it can be copied to a node with no seance checkout and run by
hand, which is exactly what an operator wants at 03:00.

    fence_ipmi off    <target> --config /path/to/seance-fence-ipmi.conf
    fence_ipmi status <target> --config /path/to/seance-fence-ipmi.conf

What it runs, per call:

    ipmitool -I lanplus -H <host> -U <user> -f <passfile> [extra] chassis power off
    ipmitool -I lanplus -H <host> -U <user> -f <passfile> [extra] chassis power status

`off` issues the power-off and then polls the status every 2 seconds until it
reads off or the budget expires.

### The credentials file

`<target>` is **not** a BMC address. It is a token naming an entry in a
root-only credentials file, so that the address, the user and the password
travel together as one administratively distributed unit:

    target_<name>_host=<bmc address or hostname>
    target_<name>_user=<bmc user>
    target_<name>_passfile=<path to a 0600 file containing only the password>
    target_<name>_extra=<extra ipmitool arguments>            (optional)

`<name>` is `[a-z0-9]+`, the same character set as node and guest keys. So a
site whose `seance.conf` says

    node_alpha_fence_driver=ipmi
    node_alpha_fence_target=alpha

has, in its credentials file:

    target_alpha_host=alpha-bmc.example.net
    target_alpha_user=fence
    target_alpha_passfile=/usr/local/etc/seance-fence-alpha.pass

The grammar is `seance.conf`'s grammar (HANDOFF.md §2.2) and the file is
**parsed, never sourced**: leading whitespace is stripped from the line and
trailing whitespace from the value, a `#` starts a comment only at the start of
a line, a carriage return anywhere is an error, a duplicate key is an error,
and an unknown key stops the load. Every fault is reported, not just the first,
as `<file>:<line>: <message>` on stderr.

### Where the file lives, and how the driver is told

There is no compiled-in default path. The natural home is
`${workdir}/etc/seance-fence-ipmi.conf`, next to `seance.conf` (decision D-3),
but only CBSD knows what `${workdir}` is, and a standalone driver may not ask
it — that is the seam (DESIGN.md §2). So the path arrives one of two ways:

- `--config <file>`, which is what a human types; or
- `SEANCE_FENCE_IPMI_CONF`, which is what `seance promote` exports.

Neither given is a contract error (exit 2), not a guess (decision D-53).

### Permissions

The credentials file and every passfile it names must have **no group or other
permission bits set** — mode `0600` or narrower. Otherwise the driver refuses
to run with exit 2 and never contacts the BMC. Ownership is not checked; the
file is expected to live in a root-only directory, and a check that pretended
to establish more than it does would be worse than an honest one.

`chmod 600 <file>` is in the error message, because the operator seeing it is
usually in a hurry.

### The password

The password is never read by the driver, never appears in `argv`, and never
appears in a diagnostic. `ipmitool` is handed `-f <passfile>` and reads the
file itself (first line, up to 20 characters, trailing `\r`, `\n` and `\t`
stripped — ipmitool 1.8.19 `lib/ipmi_main.c`). `-P <password>` would put the
secret in every `ps(1)` on the machine, so `target_<name>_extra` is screened:
it may not contain `-P`, `--password`, `-a`, `-E`, `-k`, `-y`, `-K` or `-Y`,
and it may not override `-I`, `-H`, `-U` or `-f`, which the driver sets itself.
A credentials file that tries is a contract error, not a warning.

`tests/tier1/t_fence_ipmi.sh` greps the driver's stdout, its stderr and the
shim's argv log for the password on every single run.

### How ipmitool's answers are classified

Verified against ipmitool 1.8.19 (source read from
`/usr/ports/distfiles/IPMITOOL_1_8_19.tar.gz`):

| what ipmitool did | verdict |
|---|---|
| `Chassis Power is off` on stdout (`lib/ipmi_chassis.c:206`) | off |
| `Chassis Power is on` | on |
| exit non-zero with a session/transport error (e.g. `Error: Unable to establish IPMI v2 / RMCP+ session`, `src/plugins/lanplus/lanplus.c:3572`) | unknown, exit 2 |
| exit non-zero with anything else (e.g. `Set Chassis Power Control to Down/Off failed: <completion code>`) | refused, exit 1 |
| killed by `timeout(1)` (exit 124) | unknown, exit 2 |
| exit 0 with no output | unknown, exit 2 |
| output that parses as neither on nor off | unknown, exit 2 |

The split in the middle two rows is deliberate and is the one judgement call in
the driver: a failure that is *recognisably* "we never reached the BMC" is
forceable (2), and everything else that failed is treated as the BMC having
answered and said no (1, un-forceable). Erring the other way would let an
operator `--force` past a fence that had actually been refused. The recognised
messages are listed in the driver's `FENCE_UNREACHABLE_RE`, each cited to the
ipmitool source line that emits it.

Status parsing is deliberately tolerant — it matches `is off` / `is on`
case-insensitively rather than the exact banner — because vendor BMC builds
decorate that line, and a driver that could not read a decorated line would
report "unknown" for a machine that had plainly powered off.

### Verifying reachability before you need it

`seance verify` (a later milestone) probes each node's fence endpoint **from
its peers**: every potential promoter must be able to fence every potential
corpse, and a BMC that is reachable only from the machine it controls is not a
fence at all. Until that lands, `fence_ipmi status <target>` run by hand from
each peer is the same check, one node at a time. The fence rung is the one
nobody exercises until it matters, which is why `drill fence` exists
(DESIGN.md §10).

---

## 3. Writing another driver

Redfish, a managed PDU, a lights-out card that speaks something else, or — in
the test harness — a driver that stops a jail. The recipe:

1. **Name it `drivers/fence_<name>`** and make it executable. `<name>` is what
   goes in `node_<key>_fence_driver`.
2. **Accept `off <target>` and `status <target>`**, plus `--config <file>`,
   `--timeout <seconds>` and `--help`. Ignore nothing silently: an unknown
   option is exit 2.
3. **Return the exit codes in §1**, and mean them. `off` verifies. Read the
   state back; do not trust the command's acknowledgement.
4. **Print one verdict line on stdout** in the shape above, diagnostics on
   stderr.
5. **Bound every external call** with `timeout(1)` and honour the budget.
6. **Keep credentials out of `argv` and out of logs.** If the tool cannot read
   a password from a file, that is a reason to look for another tool.
7. **Depend on nothing from `lib/`.** A driver is standalone by design: it must
   run on a node where seance is not installed, and it must not be able to
   drag CBSD-specific knowledge across the seam.
8. **`#!/bin/sh`, `set -u`, shellcheck-clean** if it is shell, like everything
   else here (HANDOFF.md §5). It does not have to be shell.

### Testing one

Do not test against real hardware in CI; test against a scripted stand-in.
`tests/drivers/ipmitool` is the pattern: an executable with the same name as
the real tool, put first on `PATH` by the test, with an environment variable
selecting which behaviour it acts out — powers off immediately, powers off
after N polls, never powers off, refuses, is unreachable, emits garbage, exits
0 with no output, hangs past the timeout. It also appends its `argv` to a log
file, which is what lets the test assert that the password went as a file
reference and never on the command line.

Every mode is exercised against both actions in
`tests/tier1/t_fence_ipmi.sh`, with the exit code asserted separately from the
verdict line. A new driver should ship the same table. The suite takes about
twenty seconds, most of it real waiting: the timeout and polling behaviour is
under test, so the clock is part of the fixture.

---

## 4. What is not here

- **No plugin ABI, no discovery, no ordering.** One driver per node, named in
  config.
- **No credential distribution.** seance never copies a file that says how to
  power a machine off; distribution is administrative and `seance verify` diffs
  the file across the mesh and complains loudly when it differs (DESIGN.md
  §11).
- **No fencing of guests.** A fence driver powers off a *node*.
- **No retry policy beyond the budget.** `off` polls until the budget is spent
  and then reports honestly. Retrying a fence that was refused is a decision
  for the human the hard abort just paged.
