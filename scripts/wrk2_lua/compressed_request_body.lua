-- POST /echo with a pre-gzipped 1050-byte plaintext body.
-- Mirrors `build_request(compressed_request_body)` in
-- scripts/bench.escript.
--
-- The .bin file ships in the repo so the script doesn't need a
-- gzip implementation in Lua. Generated with:
--   printf '%.0sabc' $(seq 1 350) | gzip > compressed_request_body.bin
local f = assert(
    io.open("/lua/compressed_request_body.bin", "rb"),
    "compressed_request_body.bin not found at /lua/ — mount " ..
    "scripts/wrk2_lua via -v scripts/wrk2_lua:/lua:ro"
)
local body = f:read("*a")
f:close()

wrk.method = "POST"
wrk.headers["Content-Type"] = "application/octet-stream"
wrk.headers["Content-Encoding"] = "gzip"
wrk.body = body
