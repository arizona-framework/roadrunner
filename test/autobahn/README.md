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
- **9.x — Performance**: large payloads up to 16 MB.
- **10.x — Misc limits**: invalid masking, oversize control frames.
- **12.x — `permessage-deflate` compression**: round-trip various
  payload sizes and compression ratios.
- **13.x — `permessage-deflate` parameters**: `*_max_window_bits`,
  `*_no_context_takeover`, auto-fragment cases.

The full suite (~500 cases) is enabled. Roadrunner passes 100 %
strict with zero exclusions.

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
