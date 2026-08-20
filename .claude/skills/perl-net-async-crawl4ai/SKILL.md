---
name: perl-net-async-crawl4ai
description: "Load when using Net::Async::Crawl4AI — the async Crawl4AI client: Future return contracts, the strategy chain, job submit and poll, retry and backoff. For the sync client see perl-www-crawl4ai."
---

# Net::Async::Crawl4AI

`Net::Async::Crawl4AI` is an `IO::Async::Notifier` subclass that wraps a
`WWW::Crawl4AI` orchestrator and drives requests through `Net::Async::HTTP`.
Every endpoint returns a `Future`, and the **same visible strategy chain** runs
asynchronously.

It reuses the pure building blocks of `WWW::Crawl4AI` (request building, page
normalization, `WWW::Crawl4AI::Detect` classification, `Attempt`/`Result`
history), so `$crawler->markdown(...)->get` returns the *same*
`WWW::Crawl4AI::Result` the sync facade would — only non-blocking.

## Construction

```perl
use IO::Async::Loop;
use Net::Async::Crawl4AI;

my $loop = IO::Async::Loop->new;
my $crawler = Net::Async::Crawl4AI->new(
  base_url         => 'http://localhost:11235',   # or $ENV{CRAWL4AI_URL}
  cloakbrowser_url => $ENV{CLOAKBROWSER_CDP_URL},  # optional
  proxy_url        => $ENV{CRAWL4AI_PROXY_URL},    # optional
  fallback         => 'auto',
  poll_interval    => 2,    # seconds between job-status polls
);
$loop->add($crawler);
```

**Must `$loop->add($crawler)`** before use — it's a Notifier. Without it the
internal `Net::Async::HTTP` has no loop and requests hang.

Constructor keys `base_url`, `api_token`, `cloakbrowser_url`, `proxy_url`,
`callback`, `fallback`, `timeout`, `min_markdown`, `client` are **forwarded to
the underlying `WWW::Crawl4AI`**. Or pass a pre-built one as `crawl4ai => $www`.
Async-only keys: `poll_interval`, `http` (inject a `Net::Async::HTTP`),
`delay_sub` (CodeRef → Future, for retry/poll delays; mainly a test hook).

The retry policy (`max_attempts`, `retry_backoff`, `retry_statuses`, `on_retry`)
lives on the underlying `WWW::Crawl4AI::Client`; the async dispatch honours it
via `delay_sub` / `loop->delay_future`.

## The headline: the async chain

```perl
my $result = $crawler->markdown('https://example.com')->get;   # crawl is an alias
$result->ok;            # did a strategy win?
$result->backend;       # crawl4ai_plain / crawl4ai_stealth / external_callback / ...
$result->markdown;
$result->attempts_json; # full history, in order
```

`markdown` / `crawl` **never fail the Future for per-strategy errors** — each
failed strategy becomes an entry in the `Result`'s attempt history, and an
all-strategies-failed run resolves to a `WWW::Crawl4AI::Result` with `ok => 0`.
The chain escalates plain → browser → stealth → cloakbrowser → proxy → callback
in cost order, stopping at the first `Detect::is_good` page. (Chain semantics
and classification live in the `perl-www-crawl4ai` skill.)

## Low-level Future endpoints

One call each, no chain:

| method | returns | endpoint |
|---|---|---|
| `crawl_once($request, $backend?)` | `Future[\@pages]` | `POST /crawl` |
| `md($url_or_request, %opts)` | `Future[$markdown]` | `POST /md` |
| `job_submit($request)` | `Future[{task_id, raw}]` | `POST /crawl/job` |
| `job_status($task_id)` | `Future[{status, pages, raw}]` | `GET /crawl/job/{id}` |
| `health` | `Future[0\|1]` (never fails) | `GET /health` |

`$request` is a `WWW::Crawl4AI::Request` or a payload hashref.

## Flow helper

### `crawl_job_and_wait($url_or_request, %opts) → Future[\%status]`

Submits a crawl job (`POST /crawl/job`) and polls `job_status` every
`poll_interval` seconds (override per call with `poll_interval => N`) until the
job reports `COMPLETED`. Resolves to the final status hash
(`{ status, pages, raw }`); **fails with a `type=job` error** on a `FAILED` job.

```perl
my $done = $crawler->crawl_job_and_wait('https://example.com')->get;
say scalar @{ $done->{pages} };
```

## Future contract

- **Success:** `$f->done($result)` — shape per the table above / a `Result` for the chain.
- **Failure:** `$f->fail($error, 'crawl4ai')` where `$error` is a
  `WWW::Crawl4AI::Error` (stringifies). Use the second category `'crawl4ai'` to
  distinguish from generic I/O failures.
  - `$err->is_transport` — network/HTTP transport (retried up to `max_attempts`).
  - `$err->is_api` — non-2xx from Crawl4AI (retried on 429/502/503/504).
  - `$err->is_job` — a `/crawl/job` finished `FAILED`. **Never retried.**
  - `$err->is_content` — chain exhausted (carried on the `Result`, not thrown).

Don't stack your own retry loops on top — transport/API retries are built in.

## Async callbacks

The `external_callback` strategy's coderef may return a plain page hashref
**or a `Future` of one** under the async client:

```perl
Net::Async::Crawl4AI->new(
  callback => sub {
    my ( $url, %opts ) = @_;
    return $some_async_scraper->fetch($url);   # returns a Future
  },
);
```

Both are handled — a returned `Future` is chained, a hashref is wrapped.

## Dispatch internals (for debugging)

- `do_request($http_request, $backend?)` — low-level dispatch through
  `Net::Async::HTTP` with retry; returns `Future[HTTP::Response]`.
- `_do_request_with_retry` — retries transport failures and retryable statuses
  via `_delay_future` (which uses `delay_sub` or `loop->delay_future`). On a
  non-retryable / exhausted non-2xx it hands the response back so the endpoint's
  parser raises the proper `api` error (with `status_code`).
- `_run_strategy_future` — runs one strategy: `build_request` → `crawl_once`
  for Crawl4AI-backed strategies, or the callback path for `external_callback`.
- `_poll_job` — `Future::Utils::repeat` until `COMPLETED`; a `FAILED` job's
  parser fails the Future and the loop stops on `is_failed`.

## Common pitfalls

- Forgetting `$loop->add($crawler)` → Futures never resolve.
- Treating a `!ok` `Result` as a Future failure — it's **data**. The chain's
  Future succeeded; inspect `$result->ok` / `$result->attempts`.
- Calling `->get` inside an event-loop callback — it runs a nested loop. Use
  `->then` / `Future::AsyncAwait` in async code paths.
- Don't confuse `crawl` (the chain → `Future[Result]`) with `crawl_once` (a
  single `POST /crawl` → `Future[\@pages]`).

## When NOT to load this skill

- For the Crawl4AI service, deployment, the control-plane model, the strategy
  chain semantics, classification, or the sync `WWW::Crawl4AI` client — load
  `perl-www-crawl4ai`.
- For generic `IO::Async` / `Future` lifecycle questions — load
  `perl-io-async-future`.
