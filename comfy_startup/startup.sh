#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# ComfyUI Assets Downloader (models + workflow only)
# - Downloads models/LORAs/etc. using manifests in a workflow repo profile
# - Copies workflow.json into $COMFY_DIR/user/default/workflows/<WORKFLOW_PROFILE>.json
# - Supports Google Drive via gdown
# - NO ComfyUI/CUDA/VSCode install; assumes ComfyUI already exists
# ============================================================================

# --------- CONFIG ---------
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
MODELS_DIR="${MODELS_DIR:-$COMFY_DIR/models}"
RETRY="${RETRY:-3}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-20}"

# Inputs for manifest download (optional fallbacks)
MANIFEST_PATH="${MANIFEST_PATH:-}"
MANIFEST_URL="${MANIFEST_URL:-}"
CATEGORY="${CATEGORY:-}"
URLS="${URLS:-}"

# Workflow repo/profile (expected to be set in env on RunPod)
WORKFLOW_REPO="${WORKFLOW_REPO:-}"
WORKFLOW_PROFILE="${WORKFLOW_PROFILE:-}"
WORKFLOW_SUBDIR="${WORKFLOW_SUBDIR:-profiles}"
WORKFLOW_MANIFEST_GLOB="${WORKFLOW_MANIFEST_GLOB:-*.manifest *.txt}"

# Workflow handling
WORKFLOW_JSON_NAME="${WORKFLOW_JSON_NAME:-workflow.json}"
WORKFLOW_DEST_DIR="${WORKFLOW_DEST_DIR:-$COMFY_DIR/user/default/workflows}"

# --------- UTIL ---------
log() { printf "[%s] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf "[%s] ERROR: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || return 1; }

category_dir() {
  case "$1" in
    checkpoints) echo "$MODELS_DIR/checkpoints" ;;
    loras) echo "$MODELS_DIR/loras" ;;
    controlnet) echo "$MODELS_DIR/controlnet" ;;
    upscale) echo "$MODELS_DIR/upscale_models" ;;
    vae) echo "$MODELS_DIR/vae" ;;
    clip) echo "$MODELS_DIR/clip" ;;
    clip_vision) echo "$MODELS_DIR/clip_vision" ;;
    embeddings) echo "$MODELS_DIR/embeddings" ;;
    unet) echo "$MODELS_DIR/unet" ;;
    ipadapter) echo "$MODELS_DIR/ipadapter" ;;
    diffusers) echo "$MODELS_DIR/diffusion_models" ;;
    *) echo "$MODELS_DIR/other" ;;
  esac
}

ensure_tooling() {
  # wget
  if ! need_cmd wget; then
    if need_cmd apt-get; then
      apt-get update -y && apt-get install -y --no-install-recommends wget ca-certificates
    elif need_cmd apk; then
      apk add --no-cache wget ca-certificates
    fi
  fi
  # gdown for Google Drive
  if ! need_cmd gdown; then
    if need_cmd python3; then
      if ! python3 -m pip --version >/dev/null 2>&1; then
        if need_cmd apt-get; then
          apt-get update -y && apt-get install -y --no-install-recommends python3-pip
        elif need_cmd apk; then
          apk add --no-cache py3-pip
        fi
      fi
      python3 -m pip install --no-cache-dir --upgrade gdown >/dev/null 2>&1 || true
    fi
  fi
  # git (for WORKFLOW_REPO)
  if [[ -n "$WORKFLOW_REPO" ]] && ! need_cmd git; then
    if need_cmd apt-get; then
      apt-get update -y && apt-get install -y --no-install-recommends git
    elif need_cmd apk; then
      apk add --no-cache git
    fi
  fi
}

download_one() {
  local url="$1"
  local dest="$2"
  local name="${3:-}"
  mkdir -p "$dest"

  if [[ "$url" == *"drive.google.com"* ]]; then
    if need_cmd gdown; then
      if [[ "$name" == "--folder" ]]; then
        log "gdown folder -> $dest :: $url"
        gdown --folder -O "$dest" "$url" || err "gdown folder failed: $url"
      else
        log "gdown -> $dest :: $url ${name:+as $name}"
        if [[ -n "$name" ]]; then
          gdown --output "$dest/$name" "$url" || err "gdown failed: $url"
        else
          gdown -O "$dest" "$url" || err "gdown failed: $url"
        fi
      fi
    else
      err "gdown not installed; cannot fetch Google Drive: $url"
    fi
  else
    # wget fallback (simple & robust enough for most cases)
    if [[ -n "$name" ]]; then
      wget -c --tries="$RETRY" --timeout="$CONNECT_TIMEOUT" -O "$dest/$name" "$url" || err "wget failed: $url"
    else
      ( cd "$dest" && wget -c --tries="$RETRY" --timeout="$CONNECT_TIMEOUT" "$url" ) || err "wget failed: $url"
    fi
  fi
}

# Parse one manifest line safely in Bash (no awk needed)
# Accepts: "<category> <url> [filename|--folder]" with arbitrary spaces/tabs
handle_manifest_line() {
  local line="$1"
  # Trim
  line="$(printf "%s" "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  # Skip empty/comment
  [[ -z "$line" || "${line:0:1}" == "#" ]] && return 0

  # First two fields: category + url; remainder is filename flag (can be empty)
  local category url rest
  IFS=' ' read -r category url rest <<<"$line"

  if [[ -z "${category:-}" || -z "${url:-}" ]]; then
    err "Malformed line: $line"
    return 1
  fi

  local dest; dest="$(category_dir "$category")"
  if [[ -n "${rest:-}" ]]; then
    download_one "$url" "$dest" "$rest"
  else
    download_one "$url" "$dest"
  fi
}

# --------- WORKFLOW REPO SUPPORT ---------
PROFILE_DIR=""
TMPDIR_CLONE=""
TMP_MANIFEST_FILE=""

fetch_manifests_from_repo() {
  local repo_url="$WORKFLOW_REPO"
  local profile="$WORKFLOW_PROFILE"
  local subdir="$WORKFLOW_SUBDIR"

  [[ -z "$repo_url" || -z "$profile" ]] && return 1
  need_cmd git || { err "git not installed"; return 1; }

  TMPDIR_CLONE="$(mktemp -d)"
  local clone_url="$repo_url"
  if [[ -n "${GITHUB_TOKEN:-}" && "$repo_url" == https://github.com/* ]]; then
    clone_url="https://${GITHUB_TOKEN}@${repo_url#https://}"
  fi

  log "Cloning $repo_url (shallow)…"
  if ! git clone --depth 1 "$clone_url" "$TMPDIR_CLONE" >/dev/null 2>&1; then
    err "Clone failed"
    return 1
  fi

  PROFILE_DIR="$TMPDIR_CLONE/$subdir/$profile"
  if [[ ! -d "$PROFILE_DIR" ]]; then
    err "Profile dir not found: $subdir/$profile"
    PROFILE_DIR=""
    return 1
  fi

  # Build a combined manifest from all matching files
  TMP_MANIFEST_FILE="$(mktemp)"
  : > "$TMP_MANIFEST_FILE"  # ensure it exists
  shopt -s nullglob
  (
    cd "$PROFILE_DIR"
    for pat in $WORKFLOW_MANIFEST_GLOB; do
      for f in $pat; do
        log "Including manifest: $f"
        cat "$f"
        echo ""
      done
    done
  ) >> "$TMP_MANIFEST_FILE"
  shopt -u nullglob

  if [[ -s "$TMP_MANIFEST_FILE" ]]; then
    MANIFEST_PATH="$TMP_MANIFEST_FILE"
    log "Loaded manifest(s) from $subdir/$profile"
  else
    log "No manifest files matched in $subdir/$profile (patterns: $WORKFLOW_MANIFEST_GLOB)"
  fi
}

copy_workflow_json_if_present() {
  [[ -z "$PROFILE_DIR" ]] && return 0
  local src="$PROFILE_DIR/$WORKFLOW_JSON_NAME"
  local dest_dir="$WORKFLOW_DEST_DIR"
  if [[ -f "$src" ]]; then
    mkdir -p "$dest_dir"
    local out="$dest_dir/${WORKFLOW_PROFILE}.json"
    cp "$src" "$out"
    log "Copied workflow JSON -> $out"
  else
    log "No $WORKFLOW_JSON_NAME found in profile; skipping."
  fi
}

cleanup() {
  [[ -n "${TMP_MANIFEST_FILE:-}" && -f "$TMP_MANIFEST_FILE" ]] && rm -f "$TMP_MANIFEST_FILE" || true
  [[ -n "${TMPDIR_CLONE:-}" && -d "$TMPDIR_CLONE" ]] && rm -rf "$TMPDIR_CLONE" || true
}
trap cleanup EXIT

# -------------------- MAIN --------------------
log "ComfyUI Assets Downloader starting…"
log "Comfy dir : $COMFY_DIR"
log "Models dir: $MODELS_DIR"

ensure_tooling

# Load manifests/workflow from repo if configured
if [[ -n "$WORKFLOW_REPO" && -n "$WORKFLOW_PROFILE" ]]; then
  fetch_manifests_from_repo || err "Failed to load repo/profile; continuing without it."
fi

# MANIFEST_URL (only if repo didn't already set MANIFEST_PATH)
if [[ -n "$MANIFEST_URL" && -z "${MANIFEST_PATH:-}" ]]; then
  local_tmp="$(mktemp)"
  log "Fetching manifest from URL: $MANIFEST_URL"
  if need_cmd curl; then
    curl -fsSL "$MANIFEST_URL" -o "$local_tmp"
  else
    wget -qO "$local_tmp" "$MANIFEST_URL"
  fi
  MANIFEST_PATH="$local_tmp"
fi

# Quick URL list mode
if [[ -n "$URLS" ]]; then
  [[ -z "${CATEGORY:-}" ]] && { err "CATEGORY required with URLS"; exit 1; }
  dest="$(category_dir "$CATEGORY")"
  IFS=',' read -r -a items <<< "$URLS"
  for u in "${items[@]}"; do
    u="$(echo "$u" | xargs)"; [[ -z "$u" ]] && continue
    download_one "$u" "$dest"
  done
  log "URL list downloads complete."
fi

# Manifest processing
if [[ -n "${MANIFEST_PATH:-}" && -f "$MANIFEST_PATH" ]]; then
  log "Using manifest: $MANIFEST_PATH"
  # Read line-by-line robustly
  while IFS= read -r line || [[ -n "$line" ]]; do
    handle_manifest_line "$line"
  done < "$MANIFEST_PATH"
  log "Manifest downloads complete."
else
  if [[ -z "$URLS" ]]; then
    log "No manifest or URL list provided; skipping model downloads."
  fi
fi

# Copy workflow.json into Comfy workspace
copy_workflow_json_if_present

log "All done."

# ---------- Health Check / Summary ----------

echo "==============================================================="
echo "✅ Download complete!"
echo
if [ -n "$WORKFLOW_REPO" ]; then
  echo "📦 Workflow repo: ${WORKFLOW_REPO}"
  [ -n "$WORKFLOW_PROFILE" ] && echo "🧩 Active profile: ${WORKFLOW_PROFILE}"
fi
echo
echo "==============================================================="
echo
