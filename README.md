# Net::Async::Crawl4AI

[IO::Async](https://metacpan.org/pod/IO::Async) companion to
[WWW::Crawl4AI](https://metacpan.org/pod/WWW::Crawl4AI). Same *crawler control
plane* — a visible strategy chain with full attempt history — but every call
returns a `Future` and nothing blocks the event loop.

The pure building blocks (request construction, page normalization, content
classification, and the `WWW::Crawl4AI::Attempt` / `WWW::Crawl4AI::Result`
history objects) are shared with the synchronous client, so
`$crawler->markdown(...)->get` returns the *same* `WWW::Crawl4AI::Result` the
sync facade would — just non-blocking.

## Synopsis

```perl
use IO::Async::Loop;
use Net::Async::Crawl4AI;

my $loop = IO::Async::Loop->new;
my $crawler = Net::Async::Crawl4AI->new(
  base_url         => 'http://localhost:11235',
  cloakbrowser_url => $ENV{CLOAKBROWSER_CDP_URL},  # optional
  poll_interval    => 2,
);
$loop->add($crawler);   # required — it's a Notifier

# Async strategy chain: plain → browser → stealth → cloakbrowser → proxy → callback
my $result = $crawler->markdown('https://example.com')->get;

say $result->markdown;
say $result->backend;        # which strategy won
say $result->cost_class;     # cheap / browser / stealth / paid
say $result->final_url;
say $result->attempts_json;  # full attempt history, JSON-safe

# Low-level single crawl (no chain) — resolves to all pages
my $pages = $crawler->crawl_once(
  WWW::Crawl4AI::Request->new( urls => 'https://example.com' )
)->get;

# Submit an async job and poll to completion
my $done = $crawler->crawl_job_and_wait('https://example.com')->get;
# { status => 'COMPLETED', pages => [...], raw => {...} }
```

## The strategy chain

`markdown` / `crawl` walk strategies in cost order and resolve at the first
result that `WWW::Crawl4AI::Detect` rates good:

| Backend | cost | What it does |
|---|---|---|
| `crawl4ai_plain` | `cheap` | headless text mode |
| `crawl4ai_browser` | `browser` | full JS render, wait for networkidle |
| `crawl4ai_stealth` | `stealth` | `enable_stealth` + random user agent |
| `crawl4ai_cloakbrowser` | `stealth` | attach to CloakBrowser via `cdp_url` *(if configured)* |
| `crawl4ai_proxy` | `paid` | stealth via `proxy_config` *(if configured)* |
| `external_callback` | `paid` | your coderef — may return a hashref **or a `Future`** *(if configured)* |

Every attempt becomes a `WWW::Crawl4AI::Attempt` in the result's history, so a
caller can see which backend won, what it cost, and on failure exactly why
(`thin_content`, `js_required`, `bot_wall_detected`, `captcha`, `http_NNN`).

## Future-returning endpoints

Low-level methods, one call each, no strategy chain:

| Method | Returns | Endpoint |
|---|---|---|
| `crawl_once($request, $backend?)` | `Future[\@pages]` | `POST /crawl` |
| `md($url_or_request, %opts)` | `Future[$markdown]` | `POST /md` |
| `job_submit($request)` | `Future[{task_id, raw}]` | `POST /crawl/job` |
| `job_status($task_id)` | `Future[{status, pages, raw}]` | `GET /crawl/job/{id}` |
| `health` | `Future[0\|1]` — never fails | `GET /health` |

Flow helper: `crawl_job_and_wait($url_or_request, %opts)` submits a job and
polls `job_status` every `poll_interval` seconds (override per call with
`poll_interval => N`) until `COMPLETED`.

## Links and deep crawl

Every `Result` exposes the links Crawl4AI found, and `deep_crawl` follows them —
but here each depth level's frontier is crawled **concurrently**:

```perl
my $r = $crawler->markdown('https://example.com')->get;
$r->urls;            # deduped absolute http(s) URLs (relative resolved, junk dropped)
$r->internal_links;  # [{ href, text, title }, ...]
$r->external_links;

my $results = $crawler->deep_crawl(
  'https://example.com',
  max_pages   => 50,    # default 25
  max_depth   => 3,     # default 2, start URL is depth 0
  same_host   => 1,     # default on
  concurrency => 8,     # frontier crawled this-many-at-a-time (default 4, async-only)
  url_filter  => sub { $_[0] !~ m{/login} },
  on_page     => sub { my ($result, $depth) = @_ },
)->get;
# Future[ \@WWW::Crawl4AI::Result ] in breadth-first order, first = start URL
```

Same semantics as `WWW::Crawl4AI::deep_crawl` (BFS, fragment-stripped dedup,
dead links surface as `ok => 0`), but the `concurrency` knob turns the event
loop loose on each level. The shared `Result` objects are identical to the sync
client's.

## Constructor parameters

All of `base_url`, `api_token`, `cloakbrowser_url`, `proxy_url`, `callback`,
`fallback`, `timeout`, `min_markdown`, `client` are forwarded to the underlying
`WWW::Crawl4AI`. Or pass a pre-built instance as `crawl4ai => $www`.

Async-only:

| Parameter | Default | Purpose |
|---|---|---|
| `poll_interval` | `2` | Seconds between job-status polls |
| `http` | auto | Pre-built `Net::Async::HTTP` |
| `delay_sub` | `loop->delay_future` | CodeRef returning a Future for delays (test hook) |

The retry policy (`max_attempts`, `retry_backoff`, `retry_statuses`,
`on_retry`) lives on the underlying `WWW::Crawl4AI::Client`.

## Errors

Endpoint Futures fail as `Future->fail($error, 'crawl4ai')` where `$error` is a
`WWW::Crawl4AI::Error`:

| `$error->type` | Meaning | Retried? |
|---|---|---|
| `transport` | could not reach the Crawl4AI server | yes |
| `api` | server returned a non-2xx response | yes (for 429/502/503/504) |
| `job` | a `/crawl/job` finished `FAILED` | no |
| `content` | carried on the `Result`, not thrown | n/a |

`markdown` / `crawl` never fail for per-strategy errors — a failed strategy is
an entry in the attempt history, and an all-strategies-failed run resolves to a
`WWW::Crawl4AI::Result` with `ok => 0`.

## Async callbacks

The `external_callback` strategy's coderef may return a plain page hashref
**or a `Future` of one**:

```perl
Net::Async::Crawl4AI->new(
  callback => sub {
    my ( $url, %opts ) = @_;
    return $async_scraper->fetch($url);  # returns a Future
  },
);
```

## Requirements

A running Crawl4AI service (default `http://localhost:11235`). See
`WWW::Crawl4AI`'s `examples/docker-compose.yml` for a container setup, plus the
optional CloakBrowser and proxy sidecars.

## Installation

```bash
cpanm Net::Async::Crawl4AI
# or from source (both repos needed):
cpanm --installdeps .
prove -l -I../p5-www-crawl4ai/lib t/
```

## See Also

- [WWW::Crawl4AI](https://metacpan.org/pod/WWW::Crawl4AI) — the synchronous client and orchestrator
- [Crawl4AI](https://github.com/unclecode/crawl4ai) — the upstream service
- [IO::Async](https://metacpan.org/pod/IO::Async), [Net::Async::HTTP](https://metacpan.org/pod/Net::Async::HTTP), [Future](https://metacpan.org/pod/Future)

## License

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.
