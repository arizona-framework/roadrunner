# Autobahn|Testsuite — WebSocket conformance

Roadrunner's WebSocket implementation (`roadrunner_ws` + `roadrunner_ws_session`)
is regression-checked against the [Autobahn|Testsuite](https://github.com/crossbario/autobahn-testsuite)
fuzzingclient. Coverage:

- **1.x — Framing**: opcode/length encodings, single + multi-frame messages.
- **2.x — Pings/pongs**: control-frame round-trip including unusual payloads.
- **3.x — Reserved bits**: server must reject RSV bits unless an extension allows.
- **4.x — Opcodes**: reserved opcodes get a close.
- **5.x — Fragmentation**: continuation handling, control-in-the-middle, fragment ordering.
- **6.x — UTF-8**: invalid byte sequences in text frames trigger 1007.
- **7.x — Close codes**: protocol-level close handshake.
- **10.x — Misc limits**: invalid masking, oversize control frames.
- **12.x — `permessage-deflate` compression**: round-trip various payload sizes.
- **13.x — `permessage-deflate` parameters**: `*_max_window_bits`, `*_no_context_takeover`.

Excluded by default:

- **9.x** — performance / very-large payloads. Slow; not a correctness concern.
- **12.1.x / 12.2.x** — mid-fragment compression scenarios where the
  client compresses every fragment rather than the whole message;
  Roadrunner follows the more common interpretation (compress the
  whole message, RSV1=1 only on the first fragment) per RFC 7692 §6.1.

## Run

```bash
./scripts/autobahn.escript
```

Boots a roadrunner WS listener on `localhost:9001` with
`roadrunner_autobahn_handler`, runs the Docker fuzzingclient, prints
the pass/fail summary, and exits non-zero on any failure.

Requires Docker. The image (`crossbario/autobahn-testsuite`) is
pulled on first run.

The HTML report lands at `test/autobahn/reports/clients/index.html`.
Open in a browser for case-by-case detail.

## Adding cases

Edit `fuzzingclient.json`. The `cases` field accepts wildcards
(`"5.*"`) and exact case IDs (`"5.19"`). `exclude-cases` overrides
inclusions. See the [autobahn fuzzingclient docs](https://github.com/crossbario/autobahn-testsuite#fuzzingclient).

## Why not in `precommit`

The fuzzingclient takes ~30s to run every test case and requires
Docker. The `precommit` gate stays fast + dependency-free; Autobahn
runs on demand and on the release branch.
