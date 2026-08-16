
## D-97 — 2026-08-16 — A living peer that cannot state its placement is not a peer with no claim (orchestrator review; Opus 5, M2/U6)
**The gap.** `gate_run` counted a peer as reached when `seance_ssh_probe`
succeeded. `placement_remote` then dropped any peer whose `seance placement`
query failed -- not installed, verb erroring, half-written reply -- onto stderr
and moved on. Every caller read the absence of a claim record as the absence of
a claim, so **a peer that was up with a broken seance made its guests look
unclaimed**: the gate released them, the ladder promoted them, and the guest
came up in two places. The split brain the gate exists to prevent, arriving by
way of a broken install rather than a broken network.
**Decision.** `placement_remote` emits two kinds of record on stdout, each
prefixed so neither can be mistaken for the other or for a node key (`claim` and
`peer` are both legal node keys, so the prefix cannot be the peer's name):

    claim<TAB><peer><TAB><guest><TAB><home>
    peer<TAB><key><TAB>answered | failed

An answer that carries no verdict line counts as `failed`: a half-written
placement is not a placement, and the records it did not reach are exactly the
ones a caller would read as "no claim". Three helpers -- `placement_claims`,
`placement_answered`, `placement_silent` -- are the only way callers read it.
**All three callers, not just the gate.** The same silence was being read the
same way in two more places, and fixing one would have been fixing the symptom:
* `gate_run`: `_reached` counts peers that ANSWERED; any living-but-silent peer
  takes the same fail-safe branch as "nobody answered" -- withhold the WHOLE
  estate, notify, with its own message naming the peer -- and `--release`
  refuses while any living peer's claims are unknown.
* `promote`: the claim check is gathered ONCE per run
  (`promote_claims_gather`), and a living peer that could not report aborts
  every guest by name. Not forceable, for the reason `probes` is not (D-44
  item 1): this is the ladder being unable to establish that the guest is not
  already running somewhere.
* `failback`: `failback_interim` refuses rather than reporting "no living peer
  claims it" -- the interim might be exactly the peer that could not answer,
  and a failback aimed at a running guest is the same accident.
**What is load-bearing, stated exactly.** The `_silent` list is what closes the
gap; counting answers rather than probes is a consistency fix that cannot fail
on its own, because the two cover each other. The mutation check is therefore
the whole revert -- probes counted AND silence ignored -- and it fails ten rows.
**Tests.** `tests/tier4/t_gate.sh` gains a peer that answers ssh and not the
question (and one that answers without a verdict line): whole estate held, the
peer named on every line and shouted on the verdict line, notification sent,
`--check` agreeing and changing nothing, `--release` refused. `ladder.tsv` gains
`peer-cannot-report` and `peer-cannot-report-forced`, both abort. Mutation
checks: `gate-counts-probes-not-answers`, `gate-ignores-silent-peers`,
`placement-drops-failed-peers`, `promote-ignores-silent-peers`.
**Cost, stated:** one node with a broken seance now freezes promotions and
failbacks fleet-wide until it is fixed or removed from the configuration. That
is the fail-safe direction, it is the same one `verify` already shouts about,
and every refusal prints the command that diagnoses it
(`ssh <peer> seance placement`).
**Reversible:** yes, but there is no reason to.
