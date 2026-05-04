# REDbot — HTTP/1.1 response audit

[REDbot](https://redbot.org) (Mark Nottingham) is "lint for HTTP
resources" — it sends GET / HEAD / conditional requests against a
URL and reports on caching, validators, content-encoding, Vary,
and other RFC 9110 / RFC 9111 hygiene items.

Roadrunner uses it as a **one-shot audit**, not a CI gate. Findings
are advisory; the harness captures the per-route reports under
`test/redbot/reports/` so they can be reviewed in context.

## Routes probed

`scripts/redbot.escript` boots a roadrunner listener with
`roadrunner_redbot_handler` and runs redbot against:

| path | shape |
|---|---|
| `/` | bare 200 text response |
| `/json` | `application/json` + `Cache-Control: no-cache` |
| `/cached` | `Cache-Control: max-age=300, public` |
| `/etag` | strong `ETag`, `max-age=60` |
| `/last-modified` | `Last-Modified` (fixed past), `max-age=60` |
| `/conditional` | honors `If-None-Match` with 304 |
| `/large` | payload above the gzip threshold (compress middleware engages) |

## Run

```bash
./scripts/redbot.escript
```

Writes per-route text reports to `test/redbot/reports/<path>.txt`
and prints a one-line summary table. Requires Docker; the
`ghcr.io/mnot/redbot` image is pulled on first run.

## Findings the harness has caught (and what was fixed)

- **Missing `Date` header** — RFC 9110 §6.6.1 says origin servers
  MUST emit `Date` on every response. Roadrunner now auto-injects
  it via `roadrunner_conn_loop:with_date/2` (deferring to a
  handler-supplied value when present).
- **Inconsistent `Vary: Accept-Encoding`** — `roadrunner_compress`
  used to add Vary only when an encoding was negotiated. RFC 9110
  §12.5.5 requires Vary on EVERY response from a resource that
  varies its representation, regardless of whether the variation
  engaged for the current request. Now always emitted (when the
  middleware is in the stack and the handler hasn't pre-encoded
  the response).

## Findings that are handler-level, not framework

REDbot also flags handler choices the framework cannot make on its
own. Examples:

- **`/etag` doesn't honor `If-None-Match`** — the framework emits
  ETag on the response, but it's the handler's call whether to
  return 304 on a matching conditional request. The
  `/conditional` route shows the pattern.
- **`/last-modified` doesn't honor `If-Modified-Since`** — same
  story; conditional handling is a per-route policy.
- **`Cache-Control: public` is "probably not necessary"** —
  REDbot points out that `public` is implied for cacheable
  responses. Informational only.

These are intentional in the test fixture; we keep them so the
report shows redbot picking them up.

## Why not a CI gate

REDbot's findings are textual / advisory. A new RFC clarification
could change category labels overnight, breaking parsing of the
report; and many findings (like `Cache-Control: public`) are
"probably not necessary" suggestions rather than spec violations.
Run on demand and review the report; don't bind PR merging to it.
