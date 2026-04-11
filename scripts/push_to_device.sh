#!/usr/bin/env bash
# push_to_device.sh — Verify the staged RAG bundle and push it to an Android device
#
# Reads rag-assets.lock.json and device_push/debug/rag_bundle_staged.json,
# verifies the staged bundle matches the pinned lock file, checks adb/device
# availability, removes stale PDFs on the device, and pushes the staged files.
# After all pushes succeed, it writes rag_bundle_deployed.json on the device.
#
# Usage:
#   scripts/push_to_device.sh
#   scripts/push_to_device.sh --models
#   scripts/push_to_device.sh --serial <device-id>

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK_FILE="$REPO_ROOT/rag-assets.lock.json"
DEVICE_PUSH="$REPO_ROOT/device_push"
INSTALL_RECORD="$DEVICE_PUSH/debug/rag_bundle_staged.json"
DEVICE_DIR="/sdcard/Android/data/com.example.app/files"
DEPLOY_RECORD_NAME="rag_bundle_deployed.json"

PUSH_MODELS=0
SERIAL=""
TMP_DIR=""

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --models)
            PUSH_MODELS=1
            shift
            ;;
        --serial)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --serial requires a device id." >&2
                exit 1
            fi
            SERIAL="$2"
            shift 2
            ;;
        -h|--help)
            awk 'NR >= 2 && NR <= 11 { sub(/^# ?/, ""); print }' "$0"
            exit 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

cleanup() {
    if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Read desired and staged state
# ---------------------------------------------------------------------------

if [[ ! -f "$LOCK_FILE" ]]; then
    echo "ERROR: $LOCK_FILE not found" >&2
    exit 1
fi

if [[ ! -f "$INSTALL_RECORD" ]]; then
    echo "ERROR: device_push/ has not been synced yet." >&2
    echo "Run: bash scripts/sync_rag_assets.sh" >&2
    exit 1
fi

LOCK_BUNDLE_VERSION=$(python3 -c "import json; print(json.load(open('$LOCK_FILE'))['bundle_version'])")
LOCK_MANIFEST_SHA=$(python3 -c "import json; print(json.load(open('$LOCK_FILE'))['manifest_sha256'])")
LOCK_SOURCE_COUNT=$(python3 -c "import json; print(json.load(open('$LOCK_FILE'))['source_count'])")

STAGED_LOCKED_VERSION=$(python3 -c "import json; print(json.load(open('$INSTALL_RECORD'))['bundle_version_locked'])")
STAGED_MANIFEST_VERSION=$(python3 -c "import json; print(json.load(open('$INSTALL_RECORD'))['bundle_version_manifest'])")
STAGED_LOCKED_SHA=$(python3 -c "import json; print(json.load(open('$INSTALL_RECORD'))['manifest_sha256_locked'])")
STAGED_ACTUAL_SHA=$(python3 -c "import json; print(json.load(open('$INSTALL_RECORD'))['manifest_sha256_actual'])")

if [[ "$STAGED_LOCKED_VERSION" != "$LOCK_BUNDLE_VERSION" || "$STAGED_MANIFEST_VERSION" != "$LOCK_BUNDLE_VERSION" ]]; then
    echo "ERROR: Staged bundle version does not match rag-assets.lock.json." >&2
    echo "  staged (locked)   : $STAGED_LOCKED_VERSION" >&2
    echo "  staged (manifest) : $STAGED_MANIFEST_VERSION" >&2
    echo "  lock file         : $LOCK_BUNDLE_VERSION" >&2
    echo "Run: bash scripts/sync_rag_assets.sh" >&2
    exit 1
fi

if [[ "$STAGED_LOCKED_SHA" != "$LOCK_MANIFEST_SHA" || "$STAGED_ACTUAL_SHA" != "$LOCK_MANIFEST_SHA" ]]; then
    echo "ERROR: Staged manifest checksum does not match rag-assets.lock.json." >&2
    echo "  staged (locked) : $STAGED_LOCKED_SHA" >&2
    echo "  staged (actual) : $STAGED_ACTUAL_SHA" >&2
    echo "  lock file       : $LOCK_MANIFEST_SHA" >&2
    echo "Run: bash scripts/sync_rag_assets.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify staged files
# ---------------------------------------------------------------------------

EMBEDDINGS_SQLITE="$DEVICE_PUSH/models/embeddings.sqlite"
DOCS_DIR="$DEVICE_PUSH/docs"
GECKO_MODEL="$DEVICE_PUSH/models/Gecko_1024_quant.tflite"
TOKENIZER_MODEL="$DEVICE_PUSH/models/sentencepiece.model"

if [[ ! -f "$EMBEDDINGS_SQLITE" ]]; then
    echo "ERROR: staged file missing: $EMBEDDINGS_SQLITE" >&2
    echo "Run: bash scripts/sync_rag_assets.sh" >&2
    exit 1
fi

if [[ ! -d "$DOCS_DIR" ]]; then
    echo "ERROR: staged docs directory missing: $DOCS_DIR" >&2
    echo "Run: bash scripts/sync_rag_assets.sh" >&2
    exit 1
fi

DOC_COUNT=$(find "$DOCS_DIR" -maxdepth 1 -type f -name "*.pdf" | wc -l | tr -d ' ')
if [[ "$DOC_COUNT" != "$LOCK_SOURCE_COUNT" ]]; then
    echo "ERROR: staged PDF count does not match rag-assets.lock.json." >&2
    echo "  staged : $DOC_COUNT" >&2
    echo "  locked : $LOCK_SOURCE_COUNT" >&2
    echo "Run: bash scripts/sync_rag_assets.sh" >&2
    exit 1
fi

if [[ "$PUSH_MODELS" -eq 1 ]]; then
    if [[ ! -f "$GECKO_MODEL" ]]; then
        echo "ERROR: staged model missing: $GECKO_MODEL" >&2
        exit 1
    fi
    if [[ ! -f "$TOKENIZER_MODEL" ]]; then
        echo "ERROR: staged model missing: $TOKENIZER_MODEL" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Resolve adb and connected device
# ---------------------------------------------------------------------------

if [[ -n "${ADB:-}" ]]; then
    ADB_BIN="$ADB"
elif command -v adb &>/dev/null; then
    ADB_BIN="$(command -v adb)"
elif [[ -x "$HOME/Library/Android/sdk/platform-tools/adb" ]]; then
    ADB_BIN="$HOME/Library/Android/sdk/platform-tools/adb"
else
    echo "ERROR: adb not found. Set ADB=/path/to/adb or install Android platform-tools." >&2
    exit 1
fi

CONNECTED_DEVICES=()
while IFS= read -r device_id; do
    if [[ -n "$device_id" ]]; then
        CONNECTED_DEVICES+=("$device_id")
    fi
done < <("$ADB_BIN" devices | awk 'NR > 1 && $2 == "device" { print $1 }')

if [[ ${#CONNECTED_DEVICES[@]} -eq 0 ]]; then
    echo "ERROR: no Android device detected by adb." >&2
    exit 1
fi

if [[ -n "$SERIAL" ]]; then
    DEVICE_SERIAL=""
    for candidate in "${CONNECTED_DEVICES[@]}"; do
        if [[ "$candidate" == "$SERIAL" ]]; then
            DEVICE_SERIAL="$candidate"
            break
        fi
    done
    if [[ -z "$DEVICE_SERIAL" ]]; then
        echo "ERROR: device '$SERIAL' is not connected." >&2
        exit 1
    fi
elif [[ ${#CONNECTED_DEVICES[@]} -eq 1 ]]; then
    DEVICE_SERIAL="${CONNECTED_DEVICES[0]}"
else
    echo "ERROR: multiple devices connected. Re-run with --serial <device-id>." >&2
    printf 'Connected devices:\n' >&2
    printf '  %s\n' "${CONNECTED_DEVICES[@]}" >&2
    exit 1
fi

ADB_ARGS=(-s "$DEVICE_SERIAL")

echo "Push staged RAG bundle"
echo "  Bundle version : $LOCK_BUNDLE_VERSION"
echo "  Device serial  : $DEVICE_SERIAL"
echo "  Device dir     : $DEVICE_DIR"
echo ""

# ---------------------------------------------------------------------------
# Prepare deployment record and device target
# ---------------------------------------------------------------------------

TMP_DIR=$(mktemp -d)
DEPLOY_RECORD_LOCAL="$TMP_DIR/$DEPLOY_RECORD_NAME"
python3 - <<PY
import json
from datetime import datetime, timezone
from pathlib import Path

lock = json.loads(Path("$LOCK_FILE").read_text())
staged = json.loads(Path("$INSTALL_RECORD").read_text())
record = {
    "schema_version": 1,
    "deployed_at_utc": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "device_serial": "$DEVICE_SERIAL",
    "device_dir": "$DEVICE_DIR",
    "bundle_version": lock.get("bundle_version", ""),
    "manifest_sha256": lock.get("manifest_sha256", ""),
    "producer_repo": lock.get("producer_repo", ""),
    "producer_commit": lock.get("producer_commit", ""),
    "chunk_count": lock.get("chunk_count"),
    "source_count": lock.get("source_count"),
    "push_models": bool($PUSH_MODELS),
    "staged_at_utc": staged.get("staged_at_utc", staged.get("installed_at_utc", "")),
    "staged_sync_mode": staged.get("sync_mode", ""),
}
Path("$DEPLOY_RECORD_LOCAL").write_text(json.dumps(record, indent=2) + "\n")
PY

"$ADB_BIN" "${ADB_ARGS[@]}" shell "mkdir -p $DEVICE_DIR && rm -f $DEVICE_DIR/*.pdf $DEVICE_DIR/$DEPLOY_RECORD_NAME $DEVICE_DIR/rag_bundle_staged.json"

# ---------------------------------------------------------------------------
# Push staged files
# ---------------------------------------------------------------------------

echo "Pushing RAG assets ..."
"$ADB_BIN" "${ADB_ARGS[@]}" push "$EMBEDDINGS_SQLITE" "$DEVICE_DIR/" >/dev/null
for pdf in "$DOCS_DIR"/*.pdf; do
    "$ADB_BIN" "${ADB_ARGS[@]}" push "$pdf" "$DEVICE_DIR/" >/dev/null
done

MODEL_COUNT=0
if [[ "$PUSH_MODELS" -eq 1 ]]; then
    echo "Pushing embedding model + tokenizer ..."
    "$ADB_BIN" "${ADB_ARGS[@]}" push "$GECKO_MODEL" "$DEVICE_DIR/" >/dev/null
    "$ADB_BIN" "${ADB_ARGS[@]}" push "$TOKENIZER_MODEL" "$DEVICE_DIR/" >/dev/null
    MODEL_COUNT=2
fi

echo "Writing deployment receipt ..."
"$ADB_BIN" "${ADB_ARGS[@]}" push "$DEPLOY_RECORD_LOCAL" "$DEVICE_DIR/" >/dev/null

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Push complete."
echo "  Bundle version : $LOCK_BUNDLE_VERSION"
echo "  RAG files      : $((DOC_COUNT + 2))"
if [[ "$PUSH_MODELS" -eq 1 ]]; then
    echo "  Model files    : $MODEL_COUNT"
fi
echo "  Device serial  : $DEVICE_SERIAL"
