-- POST /echo with Transfer-Encoding: chunked body.
-- 4 chunks × 256 bytes ('x') + zero-length terminator. Mirrors
-- `build_request(chunked_request_body)` in scripts/bench.escript.
--
-- wrk2 sets Content-Length from `wrk.body` automatically and rejects
-- chunked bodies via the standard request-build path. Override
-- `request()` so we control the wire bytes ourselves.
local chunk = string.rep("x", 256)
local frame = "100\r\n" .. chunk .. "\r\n"
local chunked_body = frame .. frame .. frame .. frame .. "0\r\n\r\n"

local req

function init(args)
    -- Build the raw HTTP/1.1 request once.
    req = "POST /echo HTTP/1.1\r\n" ..
          "Host: 127.0.0.1\r\n" ..
          "Content-Type: application/octet-stream\r\n" ..
          "Transfer-Encoding: chunked\r\n" ..
          "\r\n" ..
          chunked_body
end

function request()
    return req
end
