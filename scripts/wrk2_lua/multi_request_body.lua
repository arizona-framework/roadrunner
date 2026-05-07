-- POST /echo with 4096 bytes of 'x' body.
-- Mirrors `build_request(multi_request_body)` in scripts/bench.escript.
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/octet-stream"
wrk.body = string.rep("x", 4096)
