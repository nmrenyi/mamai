#!/usr/bin/env bash
# push_to_device.sh — Verify the staged RAG bundle and push it to an Android device
#
# Reads config/rag_assets.lock.json and device_push/bundle/debug/rag_bundle_staged.json,
# verifies the staged bundle matches the pinned lock file, checks adb/device
# availability, removes stale PDFs on the device, and pushes the staged files.
# After all pushes succeed, it writes rag_bundle_deployed.json on the device.
#
# Usage:
#   scripts/push_to_device.sh                          # RAG bundle only (embeddings + PDFs)
#   scripts/push_to_device.sh --embedding-models       # + EmbeddingGemma model + tokenizer (+ checksum markers)
#   scripts/push_to_device.sh --all-models             # + the Gemma LLM too — FULL offline provision
#   scripts/push_to_device.sh --all-models --apk app-release.apk   # also install the app
#   scripts/push_to_device.sh --serial <device-id>
#
# FULLY OFFLINE INSTALL: `--all-models` (optionally with `--apk`) pushes every
# asset the app needs — the LLM, the EmbeddingGemma retriever + tokenizer, the
# vector store, the source PDFs — AND writes the per-model `.verified` checksum
# markers the app requires. After it completes the app opens ready with ZERO
# on-device downloads (no internet needed on the phone). Markers are written only
# after the staged file's SHA-256 is confirmed against the pinned value in
# app/lib/screens/intro_page.dart, so a wrong/corrupt staged file fails loudly
# rather than provisioning a model the app would silently re-download.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK_FILE="$REPO_ROOT/config/rag_assets.lock.json"
DEVICE_PUSH="$REPO_ROOT/device_push"
INSTALL_RECORD="$DEVICE_PUSH/bundle/debug/rag_bundle_staged.json"
DEVICE_DIR="/sdcard/Android/data/com.example.app/files"
DEPLOY_RECORD_NAME="rag_bundle_deployed.json"
# Marker the app's intro_page checks (intro_page.dart:_bundleMarker) to skip the
# bundle-download prompt. The in-app extractor writes it after a successful
# tar.gz extract; sideloads via this script must write it too, or the app will
# offer to re-download the bundle on next launch.
BUNDLE_READY_MARKER=".rag_bundle_ready"

PUSH_EMBEDDING_MODELS=0
PUSH_LLM=0
APK_PATH=""
SERIAL=""
TMP_DIR=""
APP_CONFIG="$REPO_ROOT/config/app_config.json"
INTRO_PAGE="$REPO_ROOT/app/lib/screens/intro_page.dart"

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --embedding-models)
            PUSH_EMBEDDING_MODELS=1
            shift
            ;;
        --models)
            PUSH_EMBEDDING_MODELS=1
            shift
            ;;
        --all-models)
            PUSH_EMBEDDING_MODELS=1
            PUSH_LLM=1
            shift
            ;;
        --apk)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --apk requires a path to the .apk file." >&2
                exit 1
            fi
            APK_PATH="$2"
            shift 2
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
            awk 'NR >= 2 && NR <= 27 { sub(/^# ?/, ""); print }' "$0"
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
    echo "ERROR: Staged bundle version does not match config/rag_assets.lock.json." >&2
    echo "  staged (locked)   : $STAGED_LOCKED_VERSION" >&2
    echo "  staged (manifest) : $STAGED_MANIFEST_VERSION" >&2
    echo "  lock file         : $LOCK_BUNDLE_VERSION" >&2
    echo "Run: bash scripts/sync_rag_assets.sh" >&2
    exit 1
fi

if [[ "$STAGED_LOCKED_SHA" != "$LOCK_MANIFEST_SHA" || "$STAGED_ACTUAL_SHA" != "$LOCK_MANIFEST_SHA" ]]; then
    echo "ERROR: Staged manifest checksum does not match config/rag_assets.lock.json." >&2
    echo "  staged (locked) : $STAGED_LOCKED_SHA" >&2
    echo "  staged (actual) : $STAGED_ACTUAL_SHA" >&2
    echo "  lock file       : $LOCK_MANIFEST_SHA" >&2
    echo "Run: bash scripts/sync_rag_assets.sh" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Verify staged files
# ---------------------------------------------------------------------------

EMBEDDINGS_SQLITE="$DEVICE_PUSH/bundle/embeddings.sqlite"
DOCS_DIR="$DEVICE_PUSH/bundle/docs"
EMBEDDER_MODEL="$DEVICE_PUSH/models/embeddinggemma-300M_seq256_mixed-precision.tflite"
TOKENIZER_MODEL="$DEVICE_PUSH/models/embeddinggemma_tokenizer.model"
# LLM filename comes from the app config (single source of truth), so this script
# stays correct across generator swaps (Gemma 3n/4/…).
LLM_MODEL_NAME=$(python3 -c "import json; print(json.load(open('$APP_CONFIG'))['llm_model'])")
LLM_MODEL="$DEVICE_PUSH/models/$LLM_MODEL_NAME"

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
    echo "ERROR: staged PDF count does not match config/rag_assets.lock.json." >&2
    echo "  staged : $DOC_COUNT" >&2
    echo "  locked : $LOCK_SOURCE_COUNT" >&2
    echo "Run: bash scripts/sync_rag_assets.sh" >&2
    exit 1
fi

if [[ "$PUSH_EMBEDDING_MODELS" -eq 1 ]]; then
    if [[ ! -f "$EMBEDDER_MODEL" ]]; then
        echo "ERROR: staged model missing: $EMBEDDER_MODEL" >&2
        exit 1
    fi
    if [[ ! -f "$TOKENIZER_MODEL" ]]; then
        echo "ERROR: staged model missing: $TOKENIZER_MODEL" >&2
        exit 1
    fi
fi

if [[ "$PUSH_LLM" -eq 1 && ! -f "$LLM_MODEL" ]]; then
    echo "ERROR: staged LLM missing: $LLM_MODEL" >&2
    echo "Run: bash scripts/sync_models.sh" >&2
    exit 1
fi

if [[ -n "$APK_PATH" && ! -f "$APK_PATH" ]]; then
    echo "ERROR: --apk path not found: $APK_PATH" >&2
    exit 1
fi

# Pinned SHA-256 for a model filename, read from intro_page.dart's
# _modelFileSha256 (the app's source of truth). Empty if not pinned.
pinned_sha_for() {
    python3 - "$1" <<PY
import re, sys
name = sys.argv[1]
text = open("$INTRO_PAGE").read()
m = re.search(r"_modelFileSha256\s*=\s*\{(.*?)\}", text, re.S)
pairs = dict(re.findall(r'"([^"]+)"\s*:\s*"([0-9a-f]{64})"', m.group(1))) if m else {}
print(pairs.get(name, ""))
PY
}

# Push a model file + its `.verified` marker. Verifies the staged file's SHA-256
# against the app's pinned value first, so we never provision a model the app
# would silently reject and re-download. Marker content = the pinned hash (what
# the app's downloadsDone compares against).
push_model_with_marker() {
    local path="$1" name; name="$(basename "$1")"
    local pinned actual
    pinned="$(pinned_sha_for "$name")"
    actual="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [[ -n "$pinned" && "$actual" != "$pinned" ]]; then
        echo "ERROR: staged $name SHA-256 does not match the app's pinned value." >&2
        echo "  staged : $actual" >&2
        echo "  pinned : $pinned" >&2
        echo "Re-stage with scripts/sync_models.sh (the staged file is wrong/corrupt)." >&2
        exit 1
    fi
    echo "  $name ($actual)"
    "$ADB_BIN" "${ADB_ARGS[@]}" push "$path" "$DEVICE_DIR/" >/dev/null
    printf '%s' "$actual" > "$TMP_DIR/$name.verified"
    "$ADB_BIN" "${ADB_ARGS[@]}" push "$TMP_DIR/$name.verified" "$DEVICE_DIR/$name.verified" >/dev/null
}

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
# Install the APK first (if requested), so the package + its data dir exist
# ---------------------------------------------------------------------------

if [[ -n "$APK_PATH" ]]; then
    echo "Installing app: $APK_PATH"
    "$ADB_BIN" "${ADB_ARGS[@]}" install -r "$APK_PATH"
    echo ""
fi

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
    "push_models": bool($PUSH_EMBEDDING_MODELS),
    "push_embedding_models": bool($PUSH_EMBEDDING_MODELS),
    "staged_at_utc": staged.get("staged_at_utc", staged.get("installed_at_utc", "")),
    "staged_sync_mode": staged.get("sync_mode", ""),
}
Path("$DEPLOY_RECORD_LOCAL").write_text(json.dumps(record, indent=2) + "\n")
PY

"$ADB_BIN" "${ADB_ARGS[@]}" shell "mkdir -p $DEVICE_DIR && rm -f $DEVICE_DIR/*.pdf $DEVICE_DIR/$DEPLOY_RECORD_NAME $DEVICE_DIR/rag_bundle_staged.json $DEVICE_DIR/$BUNDLE_READY_MARKER"

# ---------------------------------------------------------------------------
# Push staged files
# ---------------------------------------------------------------------------

echo "Pushing RAG assets ..."
"$ADB_BIN" "${ADB_ARGS[@]}" push "$EMBEDDINGS_SQLITE" "$DEVICE_DIR/" >/dev/null
for pdf in "$DOCS_DIR"/*.pdf; do
    "$ADB_BIN" "${ADB_ARGS[@]}" push "$pdf" "$DEVICE_DIR/" >/dev/null
done

MODEL_COUNT=0
if [[ "$PUSH_LLM" -eq 1 ]]; then
    echo "Pushing LLM + checksum marker ..."
    push_model_with_marker "$LLM_MODEL"
    MODEL_COUNT=$((MODEL_COUNT + 1))
fi
if [[ "$PUSH_EMBEDDING_MODELS" -eq 1 ]]; then
    echo "Pushing embedding model + tokenizer + checksum markers ..."
    push_model_with_marker "$EMBEDDER_MODEL"
    push_model_with_marker "$TOKENIZER_MODEL"
    MODEL_COUNT=$((MODEL_COUNT + 2))
fi

echo "Writing deployment receipt ..."
"$ADB_BIN" "${ADB_ARGS[@]}" push "$DEPLOY_RECORD_LOCAL" "$DEVICE_DIR/" >/dev/null

# Write the bundle-ready marker last, only after all asset pushes have
# succeeded — same ordering as the in-app extractor. If any earlier adb push
# failed, `set -euo pipefail` would have aborted before reaching this point,
# so the device never ends up with a marker but missing assets.
echo "Writing bundle-ready marker ..."
"$ADB_BIN" "${ADB_ARGS[@]}" shell "echo -n ok > $DEVICE_DIR/$BUNDLE_READY_MARKER"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "Push complete."
echo "  Bundle version : $LOCK_BUNDLE_VERSION"
echo "  RAG files      : $((DOC_COUNT + 2))"
if [[ "$PUSH_EMBEDDING_MODELS" -eq 1 ]]; then
    echo "  Model files    : $MODEL_COUNT"
fi
echo "  Device serial  : $DEVICE_SERIAL"
