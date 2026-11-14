#!/usr/bin/env bash
#
# Run gRPC's official interop client against roadrunner.
#
# Builds the pinned grpc-go interop client (`go install`, checked against
# the Go checksum database) and runs the `official_client` case of
# `roadrunner_grpc_protobuf_interop_SUITE`, which brings up the interop
# TestService and runs the server test cases the suite lists, each in a run
# of its own. grpc-go has no client_compressed_* or
# server_compressed_* cases; the suite notes them as unsupported, and the
# gzip and deflate paths are covered by roadrunner's own suites.
#
# Requirements:
#   - go (the version grpc-go's go.mod asks for, or a newer one)
#   - mise (or rebar3 + erl on PATH)
#
# Usage:
#   ./scripts/grpc_interop.sh
#
# Exit codes:
#   0  - every case the client has passed
#   1  - a case failed
#   2  - setup failed (no go, the client did not build)

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

GRPC_GO_VERSION="v1.85.0"

command -v go >/dev/null || {
    echo "go is not on PATH" >&2
    exit 2
}

BIN_DIR="$PROJECT_DIR/_build/grpc_interop/$GRPC_GO_VERSION"
CLIENT="$BIN_DIR/client"

if [ ! -x "$CLIENT" ]; then
    mkdir -p "$BIN_DIR"
    GOBIN="$BIN_DIR" go install "google.golang.org/grpc/interop/client@$GRPC_GO_VERSION" || {
        echo "could not build the grpc-go $GRPC_GO_VERSION interop client" >&2
        exit 2
    }
fi

GRPC_INTEROP_CLIENT="$CLIENT" rebar3 ct \
    --suite=grpc_protobuf/test/roadrunner_grpc_protobuf_interop_SUITE \
    --case=official_client || exit 1
