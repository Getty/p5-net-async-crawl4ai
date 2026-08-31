# Net-Async-Crawl4AI House Rules

Apply to every task in this repository unless explicitly overridden. Bias: caution
over speed on non-trivial work; use judgment on trivial tasks. Loaded automatically
at launch (same priority as `CLAUDE.md`). Subagents get their discipline from the
skills force-loaded via `briefing.skills` — this file is for the orchestrating agent.

## Engineering discipline

1. **Think before coding** — State assumptions. When uncertain, ask rather than
   guess. Push back when a simpler approach exists. Stop when confused; name what's
   unclear.
2. **Simplicity first** — Minimum code that solves the problem. Nothing speculative.
3. **Surgical changes** — Touch only what you must. Don't "improve" adjacent code or
   formatting. Match existing style.
4. **Read before you write** — Before new code, read the target method, the retry
   loop (`_do_request_with_retry`), and how `$self->crawl4ai` / `$self->client` are
   used; a change that forks the sync building blocks silently diverges the Result.
5. **Tests verify intent** — Reproduce a bug before fixing it; leave a regression
   test behind. A test that can't fail when the logic changes is wrong.
6. **Fail loud** — "Done" is wrong if anything was skipped. "Tests pass" is wrong if
   a subtest was silently skipped.

## Delegation

This rule depends on whether the Agent/Task tool is available to you.

- **You can spawn subagents** (orchestrating main agent): Do NOT touch
  behavior-relevant code yourself — delegate to `net-async-crawl4ai-worker`. Your
  lane: coordinate, inspect, plan, review diffs, run tests, manage git, edit
  non-behavioral docs. Why: only the `net-async-crawl4ai-*` agents get their skills
  force-loaded via `briefing.skills`; you get no briefing.

  | Task | Agent |
  |---|---|
  | Implement / refactor / debug behavior-relevant code | `net-async-crawl4ai-worker` (default) |
  | Write/extend tests | `net-async-crawl4ai-test-writer` |
  | Pre-release audit | `net-async-crawl4ai-release-checker` |

- **You cannot spawn subagents** (you ARE a `net-async-crawl4ai-*` agent): The lock
  does not apply — implement, refactor, debug, and test per these rules.

Behavior-relevant = runtime behavior, the public Future interface
(crawl/markdown/deep_crawl/crawl_once/md/job_*/action endpoints), the retry and
poll dispatch, the strategy-chain walk, error classification, tests. Pure prose docs
and Changes notes are not.

## Coordination — karr board (always in scope)

Ticket coordination is the orchestrating agent's job, so `karr` is always in scope —
don't invoke the `kanban-issues-karr-cli` skill first, just use it. Git-native
kanban; state lives in `refs/karr/*`; this repo has its own board.

- `karr list --compact` / `karr board` — open work · `karr show ID` — detail
- `karr create "Title" --priority high --body '…'` — new ticket
- `karr move ID in-progress --claim NAME` · `karr handoff ID --claim NAME --note "…"`

Work that belongs to the sister `WWW::Crawl4AI` is a ticket on **that** repo's board
(`cd ../p5-www-crawl4ai`), never a direct edit — the two families are independent
repos with independent boards.

**Serialize board mutations when fanning out.** Keep implementation parallel if you
like, but loop `karr move`/`handoff`/`sync` sequentially — N landing at once is a
resource event that has OOM-rebooted a host, not a cheap command.

## Project hazards

- **The sync building blocks are shared, not forked.** Request building, page
  normalization, classification, `Result`/`Attempt` history all come from
  `WWW::Crawl4AI` via `$self->crawl4ai`/`$self->client`. The async path must produce
  the *same* `WWW::Crawl4AI::Result` as the sync facade. Goldmine consumes the ASYNC
  client at runtime, so any header/backend exposure that regresses here breaks a real
  consumer — mirror the sync path and lock it with a test (see the response_headers
  ticket).
- **`!ok` Result is data, not a failed Future.** `crawl`/`markdown`/`deep_crawl`
  succeed even when every strategy fails — the failure lives in the attempt history
  and `ok => 0`. Only transport/api/job errors fail the Future. Code (and tests) that
  treat a `!ok` Result as an exception are wrong.
- **One retry policy, mirrored.** Backoff/max_attempts/retry_statuses live on the
  underlying `WWW::Crawl4AI::Client`; the async side re-applies them in
  `_do_request_with_retry`. Don't add a second retry layer on top of built-in retries.
- **`$loop->add($crawler)` before use.** It's a Notifier — without a loop the internal
  `Net::Async::HTTP` never resolves and Futures hang. Tests add to an `IO::Async::Loop`
  and pass `delay_sub => sub { Future->done }` to skip real timeouts.

## Release — never without permission

`dzil test` / `dzil build` / `prove -l t/` are fine anytime. `dzil release` and any
upload/deploy are STRICTLY forbidden without the maintainer's explicit go-ahead —
even if a plan lists "release" as the next step. This family releases together
(`WWW::Crawl4AI` + `Net::Async::Crawl4AI`); a CPAN-release lag or a dep pin ahead of
CPAN is never a blocker. For anything heading toward release: stop and ask.

## Perl / async / Crawl4AI specifics — reference, don't restate

The async strategy chain, Future contracts, retry/poll dispatch, deep_crawl
concurrency and action endpoints live in skill `net-async-crawl4ai-core`. The chain
semantics, classification and the sync client live in `perl-www-crawl4ai`. Future
lifetime rules in `perl-io-async-future`; the not-Moo `IO::Async::Notifier` pattern
and house style in `getty-perl-core`; the Moo value objects in `getty-perl-moo`;
dist.ini/release conventions in `perl-release-dist-ini` (all force-loaded for
`net-async-crawl4ai-*` agents). Do not duplicate that content here.
