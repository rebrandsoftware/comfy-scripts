#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# ComfyUI Assets Downloader (models-only startup)
# - Downloads models/LORAs/VAEs/etc. (no ComfyUI/CUDA/VS Code install)
# - Supports HTTP(S) and Google Drive (files & folders) via `gdown`
# - Can source manifests from a Git repo subfolder using:
#       WORKFLOW_REPO, WORKFLOW_PROFILE, [optional] WORKFLOW_SUBDIR
# - Safe to run multiple times; resumes partial downloads
# ============================================================================

COMFY_DIR="${COMFY_DIR:-/workspace/runpod-slim/ComfyUI}"
MODELS_DIR="${MODELS_DIR:-$COMFY_DIR/models}"
MODEL_CONCURRENCY="${MODEL_CONCURRENCY:-6}"
RETRY="${RETRY:-3}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-20}"

MANIFEST_PATH="${MANIFEST_PATH:-}"
MANIFEST_URL="${MANIFEST_URL:-}"
CATEGORY="${CATEGORY:-}"
URLS="${URLS:-}"

# Git workflow repo support
WORKFLOW_REPO="${WORKFLOW_REPO:-}"
WORKFLOW_PROFILE="${WORKFLOW_PROFILE:-}"
WORKFLOW_SUBDIR="${WORKFLOW_SUBDIR:-profiles}"
WORKFLOW_MANIFEST_GLOB="${WORKFLOW_MANIFEST_GLOB:-*.manifest *.txt}"

category_dir() {
  case "$1" in
    checkpoints) echo "$MODELS_DIR/checkpoints" ;;
    loras) echo "$MODELS_DIR/loras" ;;
    controlnet) echo "$MODELS_DIR/controlnet" ;;
    upscale) echo "$MODELS_DIR/upscale_models" ;;
    vae) echo "$MODELS_DIR/vae" ;;
    clip) echo "$MODELS_DIR/clip" ;;
    embeddings) echo "$MODELS_DIR/embeddings" ;;
    unet) echo "$MODELS_DIR/unet" ;;
    clip_vision) echo "$MODELS_DIR/clip_vision" ;;
    ipadapter) echo "$MODELS_DIR/ipadapter" ;;
    diffusers) echo "$MODELS_DIR/diffusion_models" ;;
    *) echo "$MODELS_DIR/other" ;;
  esac
}

log() { printf "[%s] %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*"; }
err() { printf "[%s] ERROR: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || return 1; }

ensure_tooling() {
  # wget/aria2
  if ! need_cmd aria2c && ! need_cmd wget; then
    if need_cmd apt-get; then
      apt-get update -y && apt-get install -y --no-install-recommends wget ca-certificates
    elif need_cmd apk; then
      apk add --no-cache wget ca-certificates
    fi
  fi
  # gdown
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
  # git
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
    if need_cmd aria2c; then
      aria2c -x16 -s16 -k1M --retry-wait=5 --max-tries="$RETRY" -d "$dest" "$url"
    else
      (cd "$dest" && wget -c --tries="$RETRY" --timeout="$CONNECT_TIMEOUT" "$url")
    fi
  fi
}

handle_manifest_line() {
  local line="$1"
  [[ -z "$line" || "$line" =~ ^# ]] && return 0
  local category url rest
  category="$(awk '{print $1}' <<< "$line")"
  url="$(awk '{print $2}' <<< "$line")"
  rest="$(awk '{ $1=\"\"; $2=\"\"; sub(/^  */,\"\",$0); print $0 }' <<< "$line")"
  local dest; dest="$(category_dir "$category")"
  [[ -z "$url" ]] && { err "Malformed line: $line"; return 1; }
  download_one "$url" "$dest" "$rest"
}

fetch_manifests_from_repo() {
  local repo_url="$WORKFLOW_REPO"
  local profile="$WORKFLOW_PROFILE"
  local subdir="$WORKFLOW_SUBDIR"
  [[ -z "$repo_url" || -z "$profile" ]] && return 1
  need_cmd git || { err "git not installed"; return 1; }

  local tmpdir; tmpdir="$(mktemp -d)"
  local clone_url="$repo_url"
  if [[ -n "${GITHUB_TOKEN:-}" && "$repo_url" == https://github.com/* ]]; then
    clone_url="https://${GITHUB_TOKEN}@${repo_url#https://}"
  fi

  log "Cloning $repo_url (shallow)…"
  git clone --depth 1 "$clone_url" "$tmpdir" >/dev/null 2>&1 || {
    err "Clone failed"; rm -rf "$tmpdir"; return 1;
  }

  local profile_dir="$tmpdir/$subdir/$profile"
  [[ ! -d "$profile_dir" ]] && { err "Profile dir not found: $subdir/$profile"; rm -rf "$tmpdir"; return 1; }

  log "Using workflow profile dir: $subdir/$profile"
  local tmp_manifest; tmp_manifest="$(mktemp)"
  shopt -s nullglob
  (
    cd "$profile_dir"
    for pat in $WORKFLOW_MANIFEST_GLOB; do
      for f in $pat; do
        log "Including manifest: $f"
        cat "$f"
        echo ""
      done
    done
  ) > "$tmp_manifest"
  shopt -u nullglob
  [[ ! -s "$tmp_manifest" ]] && { err "No manifests found"; rm -rf "$tmpdir"; return 1; }

  MANIFEST_PATH="$tmp_manifest"
  trap 'rm -rf "$tmpdir" "$tmp_manifest" 2>/dev/null || true' EXIT
}

# -------------------- MAIN --------------------
log "🌐ComfyUI Assets Downloader starting…"
log "Comfy dir : $COMFY_DIR"
log "Models dir: $MODELS_DIR"

ensure_tooling

if [[ -n "$WORKFLOW_REPO" && -n "$WORKFLOW_PROFILE" ]]; then
  fetch_manifests_from_repo || err "Failed to load manifests from repo"
fi

if [[ -n "$MANIFEST_URL" && -z "${WORKFLOW_REPO:-}" ]]; then
  tmpfile="$(mktemp)"
  log "Fetching manifest from URL: $MANIFEST_URL"
  if need_cmd curl; then
    curl -fsSL "$MANIFEST_URL" -o "$tmpfile"
  else
    wget -qO "$tmpfile" "$MANIFEST_URL"
  fi
  MANIFEST_PATH="$tmpfile"
fi

if [[ -n "$URLS" ]]; then
  [[ -z "$CATEGORY" ]] && { err "CATEGORY required with URLS"; exit 1; }
  dest="$(category_dir "$CATEGORY")"
  IFS=',' read -r -a items <<< "$URLS"
  for u in "${items[@]}"; do
    download_one "$(echo "$u" | xargs)" "$dest"
  done
  exit 0
fi

if [[ -n "$MANIFEST_PATH" && -f "$MANIFEST_PATH" ]]; then
  log "Using manifest: $MANIFEST_PATH"
  while IFS= read -r line || [[ -n "$line" ]]; do
    handle_manifest_line "$line"
  done < "$MANIFEST_PATH"
  log "Manifest downloads complete."
else
  cat <<'EON'
No manifest or URLS specified.
Provide one of the following:
  1) WORKFLOW_REPO + WORKFLOW_PROFILE (from environment)
  2) MANIFEST_URL="https://..." ./startup_models_only.sh
  3) MANIFEST_PATH="/path/to/file" ./startup_models_only.sh
  4) URLS="url1,url2" CATEGORY=loras ./startup_models_only.sh
EON
  exit 2
fi

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
