-- OPTIONS /api with CORS-preflight headers.
-- Mirrors `build_request(cors_preflight)` in scripts/bench.escript.
wrk.method = "OPTIONS"
wrk.headers["Origin"] = "https://example.com"
wrk.headers["Access-Control-Request-Method"] = "POST"
wrk.headers["Access-Control-Request-Headers"] = "Content-Type, Authorization"
