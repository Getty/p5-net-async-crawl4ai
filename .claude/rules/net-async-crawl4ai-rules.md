# Net-Async-Crawl4AI House Rules

Apply to every task in this repository unless explicitly overridden. Bias: caution over
speed on non-trivial work; use judgment on trivial tasks. Skill content is never restated
here: the skills are the source, the agents get them force-loaded via `briefing.skills`.
The async strategy chain, Future contracts, retry/poll dispatch, deep_crawl concurrency and action
endpoints live in skill `net-async-crawl4ai-core`; chain semantics and the sync client in
`perl-www-crawl4ai`; Future lifetime rules in `perl-io-async-future`; the `IO::Async::Notifier` pattern
and house style in `getty-perl-core`; Moo value objects in `getty-perl-moo`; releases in
`perl-release-dist-ini` — don't repeat that content.

## Engineering discipline

1. **Think before coding** — State assumptions, ask rather than guess, push back when a simpler
   approach exists, stop when confused; name what's unclear.
2. **Simplicity first** — Minimum code that solves the problem, nothing speculative.
3. **Surgical changes** — Touch only what you must; don't "improve" adjacent code or formatting.
4. **Read before you write** — Before new code, read the target method, the retry loop (`_do_request_with_retry`)
   and how `$self->crawl4ai` / `$self->client` are used; a change that forks the sync building blocks diverges the Result.
5. **Tests verify intent** — Reproduce a bug before fixing it; leave a regression test behind. A
   test that can't fail when the logic changes is wrong.
6. **Fail loud** — "Done" is wrong if anything was skipped. "Tests pass" is wrong if a
   subtest was silently skipped.

## Delegation

If you can spawn subagents (orchestrating main agent): do NOT touch behavior-relevant code yourself —
delegate to `net-async-crawl4ai-worker`. Your lane: coordinate, inspect, plan, review diffs, run tests,
edit non-behavioral docs. You get no briefing — only the `net-async-crawl4ai-*` agents get the skills
force-loaded, and an unbriefed hand inside `lib/` breaks exactly the invariants they must hold.

| Task | Agent |
|---|---|
| Implement / refactor / debug behavior-relevant code | `net-async-crawl4ai-worker` (default) |
| Write/extend tests | `net-async-crawl4ai-test-writer` |
| Commits, `Changes`, card → done, pre-release audit | `net-async-crawl4ai-release-manager` |

If you ARE a `net-async-crawl4ai-*` agent, the delegation lock does not apply — implement, refactor, debug, and test per these rules.

Behavior-relevant = runtime behavior, the public Future interface (crawl/markdown/deep_crawl/crawl_once/md/
job_*/action endpoints), the retry and poll dispatch, the strategy-chain walk, error classification and
tests. Pure prose docs and Changes notes are not.

**Only `net-async-crawl4ai-release-manager` commits.** A worker leaves a commit-ready tree and hands its
card to `review`; you then dispatch the release-manager to cut the commit and close it.

## Coordination — karr board (always in scope)

Ticket coordination is the orchestrating agent's job, so `karr` is always in scope — don't invoke the
`kanban-issues-karr-coordination` skill first, just use it. Git-native kanban, state in `refs/karr/*`;
this repo has its own board.

- `karr list --compact` / `karr board` — open work · `karr show ID` — detail · `karr create "Title"
  --priority high --body '…'` — new ticket · `karr move ID in-progress --claim NAME` · `karr handoff ID
  --claim NAME --note "…"`

Work that belongs to the sister `WWW::Crawl4AI` is a ticket on **that** repo's board (`cd ../p5-www-crawl4ai`), never a direct edit.

**Serialize board mutations when fanning out.** Keep implementation parallel if you like, but loop
`karr move`/`handoff`/`sync` sequentially — N landing at once is a resource event that has OOM-rebooted a host.

## Project hazards

- **The sync building blocks are shared, not forked.** Request building, page normalization,
  classification, `Result`/`Attempt` history all come from `WWW::Crawl4AI` via `$self->crawl4ai`/
  `$self->client`; the async path must produce the *same* `WWW::Crawl4AI::Result` as the sync facade.
  Goldmine consumes the ASYNC client at runtime, so any header/backend exposure that regresses here
  breaks a real consumer — mirror the sync path and lock it with a test (see the response_headers ticket).
- **`!ok` Result is data, not a failed Future.** `crawl`/`markdown`/`deep_crawl` succeed even when
  every strategy fails — the failure lives in the attempt history and `ok => 0`. Only transport/api/
  job errors fail the Future. Code (and tests) that treat a `!ok` Result as an exception are wrong.
- **One retry policy, mirrored.** Backoff/max_attempts/retry_statuses live on the
  underlying `WWW::Crawl4AI::Client`; the async side re-applies them in
  `_do_request_with_retry`. Don't add a second retry layer on top of built-in retries.
- **`$loop->add($crawler)` before use.** It's a Notifier — without a loop the internal
  `Net::Async::HTTP` never resolves and Futures hang. Tests add to an `IO::Async::Loop` and pass
  `delay_sub => sub { Future->done }` to skip real timeouts.

## Release — never without permission

`dzil test` / `dzil build` / `prove -l t/` are fine anytime. `dzil release` and any upload/deploy are
STRICTLY forbidden without the maintainer's explicit go-ahead — even if a plan lists "release" as the
next step. This family releases together (`WWW::Crawl4AI` + `Net::Async::Crawl4AI`); a CPAN-release lag
or a dep pin ahead of CPAN is never a blocker. For anything heading toward release: stop and ask.

## Public issues — never act without instruction

`karr` is the internal agent board, churned freely. A public tracker (GitHub) carries real humans' issues,
written under the maintainer's account. Never act on a public issue on your own initiative — not even to
read it. No listing, viewing, commenting, editing, closing, or creating unless the user explicitly says so.
