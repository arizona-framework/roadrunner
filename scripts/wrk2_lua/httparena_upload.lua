-- POST /upload with 20 MB of 'x' body.
-- Mirrors `build_request(httparena_upload_20mb_*)` in scripts/bench.escript;
-- shared between the `_auto` and `_manual` scenarios.
wrk.method = "POST"
wrk.headers["Content-Type"] = "application/octet-stream"
wrk.body = string.rep("x", 20 * 1024 * 1024)
