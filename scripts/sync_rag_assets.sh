#!/usr/bin/env bash
# sync_rag_assets.sh — Fetch the pinned RAG bundle and install it into device_push/
#
# Reads rag-assets.lock.json from the repo root, downloads the bundle,
# verifies checksums, and installs:
#   device_push/models/embeddings.sqlite
#   device_push/docs/<normalized_source_id>.pdf  (55 files)
#   device_push/debug/chunks_for_rag.txt          (optional, for eval)
#
# Usage:
#   scripts/sync_rag_assets.sh               # fetch from bundle_url in lock file
#   scripts/sync_rag_assets.sh --local /path/to/rag-bundle-v1.0.0/  # use local bundle dir
#   scripts/sync_rag_assets.sh --tarball /path/to/rag-bundle-v1.0.0.tar.gz
#
# Requirements: curl, python3, sha256sum (macOS: shasum -a 256)

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK_FILE="$REPO_ROOT/rag-assets.lock.json"
DEVICE_PUSH="$REPO_ROOT/device_push"

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

MODE="remote"   # remote | local | tarball
LOCAL_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --local)    MODE="local";   LOCAL_PATH="$2"; shift 2 ;;
        --tarball)  MODE="tarball"; LOCAL_PATH="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# //'
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
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

echo "RAG asset sync"
echo "  Bundle version : $BUNDLE_VERSION"
echo "  Mode           : $MODE"
echo ""

# ---------------------------------------------------------------------------
# Acquire bundle directory
# ---------------------------------------------------------------------------

TMP_DIR=""
BUNDLE_DIR=""

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

case "$MODE" in
    local)
        BUNDLE_DIR="$LOCAL_PATH"
        if [[ ! -d "$BUNDLE_DIR" ]]; then
            echo "ERROR: local bundle dir not found: $BUNDLE_DIR" >&2
            exit 1
        fi
        ;;
    tarball)
        TMP_DIR=$(mktemp -d)
        echo "Extracting $LOCAL_PATH ..."
        tar -xzf "$LOCAL_PATH" -C "$TMP_DIR"
        BUNDLE_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "rag-bundle-*" | head -1)
        if [[ -z "$BUNDLE_DIR" ]]; then
            echo "ERROR: could not find rag-bundle-* directory inside tarball" >&2
            exit 1
        fi
        ;;
    remote)
        if [[ "$BUNDLE_URL" == *"TODO"* ]]; then
            echo "ERROR: bundle_url in $LOCK_FILE is still a placeholder." >&2
            echo "       Publish a GitHub release and update rag-assets.lock.json first," >&2
            echo "       or use --local / --tarball for a local bundle." >&2
            exit 1
        fi
        TMP_DIR=$(mktemp -d)
        TARBALL="$TMP_DIR/bundle.tar.gz"
        echo "Downloading $BUNDLE_URL ..."
        curl -L --progress-bar -o "$TARBALL" "$BUNDLE_URL"
        echo "Extracting ..."
        tar -xzf "$TARBALL" -C "$TMP_DIR"
        BUNDLE_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "rag-bundle-*" | head -1)
        if [[ -z "$BUNDLE_DIR" ]]; then
            echo "ERROR: could not find rag-bundle-* directory inside download" >&2
            exit 1
        fi
        ;;
esac

echo "  Bundle dir     : $BUNDLE_DIR"
echo ""

# ---------------------------------------------------------------------------
# Verify manifest checksum (if lock file has one)
# ---------------------------------------------------------------------------

MANIFEST="$BUNDLE_DIR/manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
    echo "ERROR: manifest.json not found in bundle" >&2
    exit 1
fi

if [[ -n "$LOCK_SHA" && "$LOCK_SHA" != "TODO"* ]]; then
    echo "Verifying manifest.json checksum ..."
    if command -v sha256sum &>/dev/null; then
        ACTUAL=$(sha256sum "$MANIFEST" | awk '{print $1}')
    else
        ACTUAL=$(shasum -a 256 "$MANIFEST" | awk '{print $1}')
    fi
    if [[ "$ACTUAL" != "$LOCK_SHA" ]]; then
        echo "ERROR: manifest.json checksum mismatch!" >&2
        echo "  expected : $LOCK_SHA" >&2
        echo "  actual   : $ACTUAL" >&2
        exit 1
    fi
    echo "  manifest.json OK ($LOCK_SHA)"
fi

# ---------------------------------------------------------------------------
# Verify per-file checksums from checksums.sha256
# ---------------------------------------------------------------------------

CHECKSUMS_FILE="$BUNDLE_DIR/checksums.sha256"
if [[ -f "$CHECKSUMS_FILE" ]]; then
    echo "Verifying artifact checksums ..."
    FAIL=0
    while IFS='  ' read -r expected_sha rel_path; do
        abs_path="$BUNDLE_DIR/$rel_path"
        if [[ ! -f "$abs_path" ]]; then
            echo "  MISSING : $rel_path" >&2
            FAIL=1
            continue
        fi
        if command -v sha256sum &>/dev/null; then
            actual_sha=$(sha256sum "$abs_path" | awk '{print $1}')
        else
            actual_sha=$(shasum -a 256 "$abs_path" | awk '{print $1}')
        fi
        if [[ "$actual_sha" != "$expected_sha" ]]; then
            echo "  MISMATCH: $rel_path" >&2
            FAIL=1
        fi
    done < "$CHECKSUMS_FILE"
    if [[ $FAIL -ne 0 ]]; then
        echo "ERROR: checksum verification failed" >&2
        exit 1
    fi
    echo "  All checksums OK"
fi

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

SRC_CHUNKS="$BUNDLE_DIR/debug/chunks_for_rag.txt"
if [[ -f "$SRC_CHUNKS" ]]; then
    DEBUG_DIR="$DEVICE_PUSH/debug"
    mkdir -p "$DEBUG_DIR"
    cp -f "$SRC_CHUNKS" "$DEBUG_DIR/chunks_for_rag.txt"
    echo "Installed debug/chunks_for_rag.txt"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Sync complete."
echo ""
echo "Next: push to device"
echo "  for f in device_push/models/embeddings.sqlite device_push/docs/*.pdf; do"
echo '    ~/Library/Android/sdk/platform-tools/adb push "$f" /sdcard/Android/data/com.example.app/files/'
echo "  done"
