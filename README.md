# Net::Async::Crawl4AI

[IO::Async](https://metacpan.org/pod/IO::Async) companion to
[WWW::Crawl4AI](https://metacpan.org/pod/WWW::Crawl4AI). Same *crawler control
plane* — a visible strategy chain with full attempt history — but every call
returns a `Future` and nothing blocks the event loop.

The pure building blocks (request building, page normalization, content
classification, and the `WWW::Crawl4AI::Attempt` / `WWW::Crawl4AI::Result`
history objects) are shared with the synchronous `WWW::Crawl4AI`, so
`$crawler->markdown(...)->get` returns the *same* `WWW::Crawl4AI::Result` the
sync facade would — just non-blocking.

## Synopsis

```perl
use IO::Async::Loop;
use Net::Async::Crawl4AI;

my $loop = IO::Async::Loop->new;
my $crawler = Net::Async::Crawl4AI->new(
  base_url         => 'http://localhost:11235',
  cloakbrowser_url => $ENV{CLOAKBROWSER_CDP_URL},   # optional
  poll_interval    => 2,
);
$loop->add($crawler);

# Async strategy chain: plain -> browser -> stealth -> cloakbrowser -> proxy -> callback
my $result = $crawler->markdown('https://example.com')->get;
say $result->markdown;
say $result->backend;        # crawl4ai_plain / crawl4ai_stealth / ...
say $result->final_url;
say $result->attempts_json;  # what was tried, in order, and why each failed

# Low-level single crawl (no chain) — all pages.
my $pages = $crawler->crawl_once(
  WWW::Crawl4AI::Request->new( urls => 'https://example.com' )
)->get;

# Submit an async crawl job and poll it to completion.
my $done = $crawler->crawl_job_and_wait('https://example.com')->get;
# { status => 'COMPLETED', pages => [...], raw => {...} }
```

## The strategy chain

`markdown` / `crawl` walk strategies in cost order and resolve at the first
result that `WWW::Crawl4AI::Detect` rates good — asynchronously:

| backend                 | cost     | what it does                                 |
|-------------------------|----------|----------------------------------------------|
| `crawl4ai_plain`        | cheap    | headless text mode                           |
| `crawl4ai_browser`      | browser  | full JS render, wait for networkidle         |
| `crawl4ai_stealth`      | stealth  | `enable_stealth` + random user agent         |
| `crawl4ai_cloakbrowser` | stealth  | attach to CloakBrowser via `cdp_url` *(if configured)* |
| `crawl4ai_proxy`        | paid     | stealth via `proxy_config` *(if configured)* |
| `external_callback`     | paid     | your coderef — may return a hashref **or a `Future`** *(if configured)* |

Every attempt becomes a `WWW::Crawl4AI::Attempt` in the result's history, so a
caller can see which backend won, what it cost, and — on failure — exactly why
(`thin_content`, `js_required`, `bot_wall_detected`, `captcha`, `http_NNN`).

## Future-returning endpoints

Low-level, one call each, no chain:

- `crawl_once($request, $backend?)` → arrayref of normalized pages (`POST /crawl`)
- `md($url_or_request, %opts)` → markdown payload (`POST /md`)
- `job_submit($request)` → `{ task_id, raw }` (`POST /crawl/job`)
- `job_status($task_id)` → `{ status, pages, raw }` (`GET /crawl/job/{id}`)
- `health` → `0`/`1`, never fails (`GET /health`)

Flow helper: `crawl_job_and_wait($url_or_request, %opts)` submits a job and
polls `job_status` every `poll_interval` seconds until `COMPLETED`.

## Errors

Endpoint Futures fail as `Future->fail($error, 'crawl4ai')` where `$error` is a
`WWW::Crawl4AI::Error` (`is_transport` / `is_api` / `is_job` / `is_content`).
Transport and retryable API statuses (429/502/503/504, honouring `Retry-After`)
are retried via `delay_future`, reusing the client's retry policy.

`markdown` / `crawl` never fail for per-strategy errors: each failure is just an
entry in the attempt history, and an all-strategies-failed run resolves to a
`WWW::Crawl4AI::Result` with `ok => 0`.

## Requirements

A running Crawl4AI service (default `http://localhost:11235`). See
`WWW::Crawl4AI`'s `examples/docker-compose.yml` for a container setup, plus the
optional CloakBrowser and proxy sidecars.

## See also

- [WWW::Crawl4AI](https://metacpan.org/pod/WWW::Crawl4AI) — the synchronous client and orchestrator
- [Crawl4AI](https://github.com/unclecode/crawl4ai) — the upstream service
- [IO::Async](https://metacpan.org/pod/IO::Async), [Net::Async::HTTP](https://metacpan.org/pod/Net::Async::HTTP), [Future](https://metacpan.org/pod/Future)

## License

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.
