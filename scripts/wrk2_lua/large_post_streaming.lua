-- POST /drain with 1 MB of 'x' body.
-- Mirrors `build_request(large_post_streaming)` in scripts/bench.escript.
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/octet-stream"
wrk.body = string.rep("x", 1048576)
