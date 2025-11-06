#!/usr/bin/env bash
set -euo pipefail

# ====== Required env ======
: "${WORKFLOW_REPO:?Set WORKFLOW_REPO (e.g. https://github.com/org/comfy-profiles.git)}"
: "${WORKFLOW_PROFILE:?Set WORKFLOW_PROFILE (folder path in repo, e.g. wan22_i2v_tdrop)}"
: "${GITHUB_TOKEN:?Set GITHUB_TOKEN (PAT with read access)}"
: "${COMFY_DIR:=/workspace/runpod-slim/ComfyUI}"

# ====== Optional env ======
PROFILES_CLONE_DIR="${PROFILES_CLONE_DIR:-/tmp/comfy-profiles}"
MANIFEST_NAME="${MANIFEST_NAME:-downloads.manifest}"

# aria2 parallelism
ARIA_CONN_PER_SERVER="${ARIA_CONN_PER_SERVER:-16}"  # -x
ARIA_SPLIT="${ARIA_SPLIT:-16}"                      # -s
ARIA_PARALLEL="${ARIA_PARALLEL:-8}"                 # -j

# ====== Prefix → ComfyUI directory map (extend as needed) ======
declare -A DEST_MAP=(
  [checkpoints]="$COMFY_DIR/models/checkpoints"
  [models]="$COMFY_DIR/models/checkpoints"
  [checkpoint]="$COMFY_DIR/models/checkpoints"

  [lora]="$COMFY_DIR/models/loras"
  [loras]="$COMFY_DIR/models/loras"

  [vae]="$COMFY_DIR/models/vae"
  [vaes]="$COMFY_DIR/models/vae"

  [clip]="$COMFY_DIR/models/clip"
  [clip_vision]="$COMFY_DIR/models/clip_vision"
  [text_encoders]="$COMFY_DIR/models/text_encoders"

  [controlnet]="$COMFY_DIR/models/controlnet"
  [t2i_adapter]="$COMFY_DIR/models/t2i_adapter"

  [upscale]="$COMFY_DIR/models/upscale_models"
  [upscale_models]="$COMFY_DIR/models/upscale_models"

  [embeddings]="$COMFY_DIR/models/embeddings"
  [ipadapter]="$COMFY_DIR/models/ipadapter"
  [unet]="$COMFY_DIR/models/unet"

  [style_models]="$COMFY_DIR/models/style_models"
  [image_projects]="$COMFY_DIR/models/image_projects"
)

# ====== Helpers ======
log()  { echo "[startup] $*"; }
warn() { echo "[startup][warn] $*" >&2; }
die()  { echo "[startup][error] $*" >&2; exit 1; }
ensure_dir() { mkdir -p "$1"; }

redact_token() { printf '%s' "$1" | sed 's/'"$GITHUB_TOKEN"'/****/g'; }
auth_repo_url() {
  local url="$1"
  if [[ "$url" =~ ^https://([^/]+)/(.+)$ ]]; then
    printf 'https://%s@%s/%s' "$GITHUB_TOKEN" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '%s' "$url"
  fi
}

install_tools() {
  log "Installing prerequisites (git, curl, python3-pip, gdown, aria2)…"

  # Decide whether to prefix with sudo
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    SUDO=""
  fi

  # Detect package manager
  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -y || true
    $SUDO apt-get install -y --no-install-recommends git curl ca-certificates python3-pip aria2 || true

  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y git curl ca-certificates python3-pip aria2 || true

  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y git curl ca-certificates python3-pip aria2 || true

  elif command -v apk >/dev/null 2>&1; then
    # Alpine
    $SUDO apk add --no-cache git curl ca-certificates python3 py3-pip aria2 || true
  else
    warn "No known package manager found; skipping system install."
  fi

  # Ensure pip is available
  if ! command -v pip3 >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    log "pip3 missing; attempting ensurepip…"
    python3 -m ensurepip --upgrade || true
  fi

  # Install gdown if missing (use user mode when not root)
  if ! command -v gdown >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      python3 -m pip install --upgrade --no-cache-dir gdown || true
    else
      python3 -m pip install --user --upgrade --no-cache-dir gdown || true
      export PATH="$HOME/.local/bin:$PATH"
    fi
  fi

  # If aria2c is still missing, it's okay—script will fall back to curl
  if ! command -v aria2c >/dev/null 2>&1; then
    warn "aria2c not available; downloads will use curl (serial)."
  fi
}

git_full_clone() {
  rm -rf "$PROFILES_CLONE_DIR"
  ensure_dir "$PROFILES_CLONE_DIR"

  local auth_url; auth_url="$(auth_repo_url "$WORKFLOW_REPO")"
  log "Cloning full repo $(redact_token "$WORKFLOW_REPO") → $PROFILES_CLONE_DIR"
  git clone "$auth_url" "$PROFILES_CLONE_DIR" || die "Failed to clone repo"
}

is_google_drive_url() {
  local url="$1"
  [[ "$url" == *"drive.google.com/"* || "$url" == *"docs.google.com/"* ]]
}

extract_gdrive_id() {
  local url="$1" id=""
  if [[ "$url" =~ /file/d/([^/]+)/ ]]; then id="${BASH_REMATCH[1]}"; fi
  if [[ -z "$id" && "$url" =~ [\?\&]id=([^&]+) ]]; then id="${BASH_REMATCH[1]}"; fi
  printf '%s' "$id"
}

# Queues for aria2 (non-GDrive) and direct gdown (GDrive)
ARIA_INPUT_FILE=""   # created lazily
queue_aria() {
  local url="$1" dest_dir="$2" override="${3:-}"
  ensure_dir "$dest_dir"
  if [[ -z "$ARIA_INPUT_FILE" ]]; then
    ARIA_INPUT_FILE="$(mktemp)"
  fi
  {
    echo "$url"
    echo " dir=$dest_dir"
    if [[ -n "$override" ]]; then
      echo " out=$override"
    fi
  } >> "$ARIA_INPUT_FILE"
}

download_gdrive() {
  local url="$1" dest_dir="$2" override="${3:-}"
  ensure_dir "$dest_dir"
  local id; id="$(extract_gdrive_id "$url")"
  [[ -n "$id" ]] || die "Could not extract Google Drive id from: $url"
  if [[ -n "$override" ]]; then
    log "gdown → $dest_dir/$override"
    gdown --fuzzy "https://drive.google.com/uc?id=$id" -O "$dest_dir/$override"
  else
    log "gdown → $dest_dir (Drive filename)"
    gdown --fuzzy "https://drive.google.com/uc?id=$id" -O "$dest_dir/"
  fi
}

flush_aria_queue() {
  [[ -z "${ARIA_INPUT_FILE:-}" ]] && return 0
  if command -v aria2c >/dev/null 2>&1; then
    log "Starting parallel downloads via aria2c…"
    aria2c \
      --input-file="$ARIA_INPUT_FILE" \
      --check-certificate=true \
      --continue=true \
      --allow-overwrite=true \
      --auto-file-renaming=false \
      --file-allocation=none \
      --content-disposition-default-utf8=true \
      -x "$ARIA_CONN_PER_SERVER" -s "$ARIA_SPLIT" -j "$ARIA_PARALLEL" \
      --retry-wait=2 --max-tries=5
  else
    warn "aria2c not found; falling back to curl (serial)."
    awk '
      /^[^ ]/ { if (url) { print url "|" dir "|" out; url=""; dir=""; out="" } url=$0; next }
      /^\ dir=/ { sub(/^ dir=/,""); dir=$0; next }
      /^\ out=/ { sub(/^ out=/,""); out=$0; next }
      END { if (url) print url "|" dir "|" out }
    ' "$ARIA_INPUT_FILE" | while IFS='|' read -r url dir out; do
      mkdir -p "$dir"
      if [[ -n "$out" ]]; then
        curl -L --fail --retry 5 --retry-delay 2 -o "$dir/$out" "$url"
      else
        ( cd "$dir" && curl -L --fail --retry 5 --retry-delay 2 -J -O "$url" )
      fi
    done
  fi
  rm -f "$ARIA_INPUT_FILE"
  ARIA_INPUT_FILE=""
}

download_to_bucket() {
  local prefix="$1" url="$2" override="${3:-}"
  local dest="${DEST_MAP[$prefix]:-}"
  if [[ -z "$dest" ]]; then
    warn "Unknown prefix '$prefix'; defaulting to checkpoints."
    dest="$COMFY_DIR/models/checkpoints"
  fi
  if is_google_drive_url "$url"; then
    download_gdrive "$url" "$dest" "$override"
  else
    queue_aria "$url" "$dest" "$override"
  fi
}

copy_workflows() {
  local src="$1/workflows"
  local dst="$COMFY_DIR/users/default/workflows"
  if [[ -d "$src" ]]; then
    ensure_dir "$dst"
    log "Copying workflows: $src → $dst"
    cp -R "$src/"* "$dst/" 2>/dev/null || true
  else
    warn "No workflows directory at $src"
  fi
}

run_post_script() {
  local post="$1/post.sh"
  if [[ -f "$post" ]]; then
    log "Running post.sh…"
    chmod +x "$post"
    WORKFLOW_REPO="$WORKFLOW_REPO" \
    WORKFLOW_PROFILE="$WORKFLOW_PROFILE" \
    COMFY_DIR="$COMFY_DIR" \
    "$post"
  else
    log "No post.sh present; skipping."
  fi
}

# ====== Main ======
log "Starting ComfyUI startup"
log "COMFY_DIR: $COMFY_DIR"
log "WORKFLOW_REPO: $(redact_token "$WORKFLOW_REPO")"
log "WORKFLOW_PROFILE: $WORKFLOW_PROFILE"

install_tools
ensure_dir "$COMFY_DIR"

git_full_clone

PROFILE_DIR="$PROFILES_CLONE_DIR/$WORKFLOW_PROFILE"
[[ -d "$PROFILE_DIR" ]] || die "Profile folder not found: $PROFILE_DIR"

MANIFEST_PATH="$PROFILE_DIR/$MANIFEST_NAME"
[[ -f "$MANIFEST_PATH" ]] || die "Manifest not found: $MANIFEST_PATH"

log "Processing manifest: $MANIFEST_PATH"

# Read lines: PREFIX URL [FILENAME...]
while IFS= read -r line || [[ -n "$line" ]]; do
  # trim
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" || "$line" =~ ^# ]] && continue

  kind=""; url=""; rest=""
  read -r kind url rest <<<"$line"
  if [[ -z "${kind:-}" || -z "${url:-}" ]]; then
    warn "Malformed line (need PREFIX and URL): $line"
    continue
  fi

  # capture filename override (the rest of line, preserving spaces/quotes)
  filename_override=""
  if [[ -n "$rest" ]]; then
    tail="${line#"$kind"}"; tail="${tail# }"
    tail="${tail#"$url"}";  tail="${tail# }"
    filename_override="$tail"
    filename_override="${filename_override%\"}"; filename_override="${filename_override#\"}"
    filename_override="${filename_override%\'}"; filename_override="${filename_override#\'}"
  fi

  log "→ $kind :: $url ${filename_override:+as $filename_override}"
  download_to_bucket "$kind" "$url" "$filename_override"
done < "$MANIFEST_PATH"

# Execute queued parallel downloads
flush_aria_queue

# Workflows & post
copy_workflows "$PROFILE_DIR"
run_post_script "$PROFILE_DIR"

log "✨🚀 Startup complete! ✅🎨🧠🦙"