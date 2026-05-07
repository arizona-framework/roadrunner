-- POST /echo with 256 bytes of 'x' body.
-- Mirrors `build_request(echo)` in scripts/bench.escript.
wrk.method = "POST"
wrk.headers["User-Agent"] = "roadrunner-bench/1.0"
wrk.headers["Accept"] = "*/*"
wrk.headers["Content-Type"] = "application/octet-stream"
wrk.body = string.rep("x", 256)
