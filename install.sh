#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$ROOT/target/simplemarkdown-install"
LIB_DIR="$ROOT/lib"
BINARY_NAME="simplemarkdown-daemon"
MIN_RUST_MINOR=88

if ! command -v cargo >/dev/null 2>&1 || ! command -v rustc >/dev/null 2>&1; then
  echo "error: Rust 1.88 or newer and Cargo are required." >&2
  exit 1
fi

rustc_version="$(rustc --version)"
if [[ "$rustc_version" =~ ^rustc[[:space:]]+([0-9]+)\.([0-9]+)\. ]]; then
  rustc_major="${BASH_REMATCH[1]}"
  rustc_minor="${BASH_REMATCH[2]}"
  if (( rustc_major < 1 || (rustc_major == 1 && rustc_minor < MIN_RUST_MINOR) )); then
    echo "error: Rust 1.88 or newer is required; found $rustc_version." >&2
    exit 1
  fi
else
  echo "error: could not determine the Rust version from: $rustc_version" >&2
  exit 1
fi

host="$(rustc -vV | sed -n 's/^host: //p')"
if [[ -z "$host" ]]; then
  echo "error: could not determine the native Rust target." >&2
  exit 1
fi

cargo build \
  --manifest-path "$ROOT/Cargo.toml" \
  --release \
  --locked \
  --target "$host" \
  --target-dir "$TARGET_DIR"

suffix=""
if [[ "$host" == *windows* ]]; then
  suffix=".exe"
fi
source_binary="$TARGET_DIR/$host/release/$BINARY_NAME$suffix"
destination="$LIB_DIR/$BINARY_NAME$suffix"

"$source_binary" --self-test >/dev/null
mkdir -p "$LIB_DIR"
temporary="$(mktemp "$LIB_DIR/.simplemarkdown-daemon.XXXXXX")"
trap 'rm -f "$temporary"' EXIT
cp "$source_binary" "$temporary"
chmod 0755 "$temporary" || true
mv -f "$temporary" "$destination"
trap - EXIT

echo "Installed SimpleMarkdown backend to $destination"
