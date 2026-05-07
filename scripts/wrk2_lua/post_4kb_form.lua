-- POST /form with a ~4 KB urlencoded form body.
-- Mirrors `post_4kb_form_body/0` in scripts/bench.escript:
-- 128 pairs of `kNNN=<27-char value>` joined by `&`. Each pair is
-- 32 bytes; 128 × 32 - 1 (trailing `&` dropped) = 4095 bytes.
-- ASCII-only so the qs parser doesn't hit the percent-decode slow
-- path (matches POST_FORM_VALUE in bench.escript).
local pairs_t = {}
local value = "abcdefghijklmnopqrstuvwxyz0"
for i = 1, 128 do
    pairs_t[i] = string.format("k%03d=%s", i, value)
end
local body = table.concat(pairs_t, "&")

wrk.method = "POST"
wrk.headers["Content-Type"] = "application/x-www-form-urlencoded"
wrk.body = body
