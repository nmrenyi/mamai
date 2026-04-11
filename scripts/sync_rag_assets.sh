#!/usr/bin/env bash
# sync_rag_assets.sh — Fetch the pinned RAG bundle into a local cache and
# stage the active version into device_push/
#
# Reads rag-assets.lock.json from the repo root, downloads the bundle,
# caches it under _scratch/rag_bundle_cache/<version>/, verifies checksums,
# and installs:
#   device_push/models/embeddings.sqlite
#   device_push/docs/<normalized_source_id>.pdf  (55 files)
#   device_push/debug/chunks_for_rag.txt          (optional, for eval)
#   device_push/debug/rag_bundle_staged.json      (staged bundle provenance)
#
# Usage:
#   scripts/sync_rag_assets.sh               # fetch from bundle_url in lock file
#
# Requirements: python3, tar, curl or gh, sha256sum (macOS: shasum -a 256)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK_FILE="$REPO_ROOT/rag-assets.lock.json"
DEVICE_PUSH="$REPO_ROOT/device_push"
CACHE_ROOT="$REPO_ROOT/_scratch/rag_bundle_cache"

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            awk 'NR >= 2 && NR <= 14 { sub(/^# ?/, ""); print }' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Read lock file
# ---------------------------------------------------------------------------

if [[ ! -f "$LOCK_FILE" ]]; then
    echo "ERROR: $LOCK_FILE not found" >&2
    exit 1
fi

BUNDLE_VERSION=$(python3 -c "import json,sys; print(json.load(open('$LOCK_FILE'))['bundle_version'])")
BUNDLE_URL=$(python3     -c "import json,sys; print(json.load(open('$LOCK_FILE'))['bundle_url'])")
LOCK_SHA=$(python3       -c "import json,sys; d=json.load(open('$LOCK_FILE')); print(d.get('manifest_sha256',''))")
CACHE_DIR="$CACHE_ROOT/$BUNDLE_VERSION"

echo "RAG asset sync"
echo "  Bundle version : $BUNDLE_VERSION"
echo "  Cache dir      : $CACHE_DIR"
echo ""

# ---------------------------------------------------------------------------
# Acquire bundle directory
# ---------------------------------------------------------------------------

TMP_DIR=""
BUNDLE_DIR=""
BUNDLE_SOURCE=""
MANIFEST=""
MANIFEST_SHA_ACTUAL=""

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

compute_manifest_sha() {
    if command -v sha256sum &>/dev/null; then
        MANIFEST_SHA_ACTUAL=$(sha256sum "$MANIFEST" | awk '{print $1}')
    else
        MANIFEST_SHA_ACTUAL=$(shasum -a 256 "$MANIFEST" | awk '{print $1}')
    fi
}

verify_bundle() {
    MANIFEST="$BUNDLE_DIR/manifest.json"
    if [[ ! -f "$MANIFEST" ]]; then
        echo "ERROR: manifest.json not found in bundle: $BUNDLE_DIR" >&2
        return 1
    fi

    compute_manifest_sha

    if [[ -n "$LOCK_SHA" && "$LOCK_SHA" != "TODO"* ]]; then
        echo "Verifying manifest.json checksum ..."
        if [[ "$MANIFEST_SHA_ACTUAL" != "$LOCK_SHA" ]]; then
            echo "ERROR: manifest.json checksum mismatch!" >&2
            echo "  expected : $LOCK_SHA" >&2
            echo "  actual   : $MANIFEST_SHA_ACTUAL" >&2
            return 1
        fi
        echo "  manifest.json OK ($LOCK_SHA)"
    fi

    CHECKSUMS_FILE="$BUNDLE_DIR/checksums.sha256"
    if [[ -f "$CHECKSUMS_FILE" ]]; then
        echo "Verifying artifact checksums ..."
        local fail=0
        while IFS='  ' read -r expected_sha rel_path; do
            local abs_path="$BUNDLE_DIR/$rel_path"
            local actual_sha
            if [[ ! -f "$abs_path" ]]; then
                echo "  MISSING : $rel_path" >&2
                fail=1
                continue
            fi
            if command -v sha256sum &>/dev/null; then
                actual_sha=$(sha256sum "$abs_path" | awk '{print $1}')
            else
                actual_sha=$(shasum -a 256 "$abs_path" | awk '{print $1}')
            fi
            if [[ "$actual_sha" != "$expected_sha" ]]; then
                echo "  MISMATCH: $rel_path" >&2
                fail=1
            fi
        done < "$CHECKSUMS_FILE"
        if [[ $fail -ne 0 ]]; then
            echo "ERROR: checksum verification failed" >&2
            return 1
        fi
        echo "  All checksums OK"
    fi

    return 0
}

download_bundle_to_cache() {
    TMP_DIR=$(mktemp -d)
    local tarball="$TMP_DIR/bundle.tar.gz"
    local extracted_dir=""

    echo "Cache miss or invalid cache entry. Downloading $BUNDLE_URL ..."

    # GitHub release asset downloads can require auth-aware redirect handling.
    # Prefer gh when available, otherwise fall back to curl for public repos.
    if command -v gh &>/dev/null; then
        local gh_repo gh_tag gh_file
        gh_repo=$(echo "$BUNDLE_URL" | sed -E 's|https://github.com/([^/]+/[^/]+)/releases/.*|\1|')
        gh_tag=$(echo "$BUNDLE_URL"  | sed -E 's|.*/releases/download/([^/]+)/.*|\1|')
        gh_file=$(basename "$BUNDLE_URL")
        echo "Downloading via gh: $gh_repo $gh_tag $gh_file ..."
        gh release download "$gh_tag" --repo "$gh_repo" --pattern "$gh_file" --dir "$TMP_DIR"
        mv "$TMP_DIR/$gh_file" "$tarball"
    else
        curl -L --progress-bar -o "$tarball" "$BUNDLE_URL"
    fi

    echo "Extracting ..."
    tar -xzf "$tarball" -C "$TMP_DIR"
    extracted_dir=$(find "$TMP_DIR" -maxdepth 1 -type d -name "rag-bundle-*" | head -1)
    if [[ -z "$extracted_dir" ]]; then
        echo "ERROR: could not find rag-bundle-* directory inside download" >&2
        exit 1
    fi

    rm -rf "$CACHE_DIR"
    mkdir -p "$CACHE_DIR"
    cp -R "$extracted_dir"/. "$CACHE_DIR"/
}

if [[ "$BUNDLE_URL" == *"TODO"* ]]; then
    echo "ERROR: bundle_url in $LOCK_FILE is still a placeholder." >&2
    echo "       Publish a GitHub release and update rag-assets.lock.json first." >&2
    exit 1
fi

mkdir -p "$CACHE_ROOT"

if [[ -d "$CACHE_DIR" ]]; then
    BUNDLE_DIR="$CACHE_DIR"
    BUNDLE_SOURCE="cache"
    echo "Found cached bundle: $CACHE_DIR"
    if ! verify_bundle; then
        echo "Cached bundle failed verification. Refreshing from GitHub release ..."
        download_bundle_to_cache
        BUNDLE_DIR="$CACHE_DIR"
        BUNDLE_SOURCE="github_release"
        verify_bundle
    fi
else
    download_bundle_to_cache
    BUNDLE_DIR="$CACHE_DIR"
    BUNDLE_SOURCE="github_release"
    verify_bundle
fi

echo "  Bundle dir     : $BUNDLE_DIR"
echo "  Bundle source  : $BUNDLE_SOURCE"
echo ""

# ---------------------------------------------------------------------------
# Read manifest for version info
# ---------------------------------------------------------------------------

MANIFEST_VERSION=$(python3 -c "import json; print(json.load(open('$MANIFEST'))['bundle_version'])")
MANIFEST_CHUNKS=$(python3  -c "import json; print(json.load(open('$MANIFEST'))['chunk_count'])")
MANIFEST_DOCS=$(python3    -c "import json; print(json.load(open('$MANIFEST'))['source_count'])")
echo ""
echo "Bundle contents:"
echo "  Version : $MANIFEST_VERSION"
echo "  Chunks  : $MANIFEST_CHUNKS"
echo "  PDFs    : $MANIFEST_DOCS"
echo ""

# ---------------------------------------------------------------------------
# Install embeddings.sqlite
# ---------------------------------------------------------------------------

MODELS_DIR="$DEVICE_PUSH/models"
mkdir -p "$MODELS_DIR"

SRC_SQLITE="$BUNDLE_DIR/runtime/embeddings.sqlite"
DST_SQLITE="$MODELS_DIR/embeddings.sqlite"
echo "Installing embeddings.sqlite ..."
cp -f "$SRC_SQLITE" "$DST_SQLITE"
SIZE_MB=$(python3 -c "import os; print(f'{os.path.getsize(\"$DST_SQLITE\")/1024/1024:.1f}')")
echo "  -> $DST_SQLITE  (${SIZE_MB} MB)"

# ---------------------------------------------------------------------------
# Install PDFs (replacing old non-normalized names)
# ---------------------------------------------------------------------------

DOCS_DIR="$DEVICE_PUSH/docs"
mkdir -p "$DOCS_DIR"

# Remove old PDFs (may have non-normalized names from before this workflow)
echo "Clearing old PDFs from device_push/docs/ ..."
find "$DOCS_DIR" -name "*.pdf" -delete

BUNDLE_DOCS="$BUNDLE_DIR/docs"
PDF_COUNT=0
echo "Installing $MANIFEST_DOCS PDFs ..."
for pdf in "$BUNDLE_DOCS"/*.pdf; do
    cp -f "$pdf" "$DOCS_DIR/"
    PDF_COUNT=$((PDF_COUNT + 1))
done
echo "  -> $DOCS_DIR/  ($PDF_COUNT files)"

# ---------------------------------------------------------------------------
# Install debug chunks (optional)
# ---------------------------------------------------------------------------

DEBUG_DIR="$DEVICE_PUSH/debug"
mkdir -p "$DEBUG_DIR"

SRC_CHUNKS="$BUNDLE_DIR/debug/chunks_for_rag.txt"
if [[ -f "$SRC_CHUNKS" ]]; then
    cp -f "$SRC_CHUNKS" "$DEBUG_DIR/chunks_for_rag.txt"
    echo "Installed debug/chunks_for_rag.txt"
fi

# Stamp the staged bundle metadata into device_push/ so the staging folder is
# self-describing even though the large bundle files themselves are gitignored.
INSTALL_RECORD="$DEBUG_DIR/rag_bundle_staged.json"
python3 - <<PY
import json
from datetime import datetime, timezone
from pathlib import Path

lock = json.loads(Path("$LOCK_FILE").read_text())
manifest = json.loads(Path("$MANIFEST").read_text())
record = {
    "schema_version": 1,
    "staged_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "sync_mode": "$BUNDLE_SOURCE",
    "bundle_version_locked": lock.get("bundle_version", ""),
    "bundle_version_manifest": manifest.get("bundle_version", ""),
    "bundle_url": lock.get("bundle_url", ""),
    "manifest_sha256_locked": lock.get("manifest_sha256", ""),
    "manifest_sha256_actual": "$MANIFEST_SHA_ACTUAL",
    "producer_repo": lock.get("producer_repo", ""),
    "producer_commit": lock.get("producer_commit", ""),
    "chunk_count_locked": lock.get("chunk_count"),
    "source_count_locked": lock.get("source_count"),
    "chunk_count_manifest": manifest.get("chunk_count"),
    "source_count_manifest": manifest.get("source_count"),
    "cache_dir": "$CACHE_DIR",
}
Path("$INSTALL_RECORD").write_text(json.dumps(record, indent=2) + "\n")
PY
echo "Stamped staged bundle metadata: $INSTALL_RECORD"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Sync complete."
echo ""
echo "Next: push the staged bundle to device"
echo "  bash scripts/push_to_device.sh"
