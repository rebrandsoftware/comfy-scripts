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

# aria2 parallelism (tune as desired)
ARIA_CONN_PER_SERVER="${ARIA_CONN_PER_SERVER:-16}"  # -x
ARIA_SPLIT="${ARIA_SPLIT:-16}"                      # -s
ARIA_PARALLEL="${ARIA_PARALLEL:-8}"                 # -j
# Extra flags for aria2 (e.g., "--console-log-level=warn --summary-interval=0")
ARIA_EXTRA_FLAGS="${ARIA_EXTRA_FLAGS:-}"

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

  # New: diffusion_models bucket
  [diffusion_models]="$COMFY_DIR/models/diffusion_models"
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

# ---- robust installer (works with/without sudo, multiple distros)
install_tools() {
  log "Installing prerequisites (git, curl, python3-pip, gdown, aria2)…"

  # sudo (if present)
  local SUDO=""
  if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

  if command -v apt-get >/dev/null 2>&1; then
    $SUDO apt-get update -y || true
    $SUDO apt-get install -y --no-install-recommends git curl ca-certificates python3-pip aria2 || true
  elif command -v dnf >/dev/null 2>&1; then
    $SUDO dnf install -y git curl ca-certificates python3-pip aria2 || true
  elif command -v yum >/dev/null 2>&1; then
    $SUDO yum install -y git curl ca-certificates python3-pip aria2 || true
  elif command -v apk >/dev/null 2>&1; then
    $SUDO apk add --no-cache git curl ca-certificates python3 py3-pip aria2 || true
  else
    warn "No known package manager found; skipping system package install."
  fi

  # Ensure pip is available
  if ! command -v pip3 >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    log "pip3 missing; attempting ensurepip…"
    python3 -m ensurepip --upgrade || true
  fi

  # Install gdown (root or user mode)
  if ! command -v gdown >/dev/null 2>&1; then
    if [ "$(id -u)" -eq 0 ]; then
      python3 -m pip install --upgrade --no-cache-dir gdown || true
    else
      python3 -m pip install --user --upgrade --no-cache-dir gdown || true
      export PATH="$HOME/.local/bin:$PATH"
    fi
  fi

  if ! command -v aria2c >/dev/null 2>&1; then
    warn "aria2c not available; will fall back to curl (serial)."
  fi
}

# ---- full clone (no sparse/filters; simplest + most compatible)
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

# --- helpers to determine a filename (Python-based, awk-free)
detect_download_filename() {
  # Try: (1) final response headers Content-Disposition
  #      (2) response-content-disposition in final URL
  #      (3) basename from original URL
  local url="$1"

  local headers final_url
  headers="$(curl -sIL "$url")" || headers=""
  final_url="$(curl -sIL -o /dev/null -w '%{url_effective}' "$url")" || final_url="$url"

  python3 - "$url" "$final_url" <<'PY'
import sys, re, urllib.parse

orig_url, final_url = sys.argv[1], sys.argv[2]
headers = sys.stdin.read()

def decode(s):
    try:
        return urllib.parse.unquote(s)
    except Exception:
        return s

def from_cd(line):
    # filename*=… (RFC 5987)
    m = re.search(r'filename\*\s*=\s*([^;]+)', line, flags=re.I)
    if m:
        v = m.group(1).strip().strip('"')
        if "''" in v:
            _, _, val = v.partition("''")
            return decode(val)
        return decode(v.strip('"'))
    # filename="…"
    m = re.search(r'filename\s*=\s*"([^"]+)"', line, flags=re.I)
    if m:
        return decode(m.group(1))
    # filename=bare
    m = re.search(r'filename\s*=\s*([^;]+)', line, flags=re.I)
    if m:
        return decode(m.group(1).strip().strip('"'))
    return None

# 1) parse headers
for line in headers.splitlines():
    if line.lower().startswith('content-disposition:'):
        name = from_cd(line)
        if name:
            print(name)
            sys.exit(0)

# 2) look in final URL query param response-content-disposition
if 'response-content-disposition=' in final_url:
    q = urllib.parse.urlsplit(final_url).query
    params = urllib.parse.parse_qs(q)
    rcd = params.get('response-content-disposition', [None])[0]
    if rcd:
        name = from_cd(urllib.parse.unquote(rcd))
        if name:
            print(name)
            sys.exit(0)

# 3) fallback: basename of the original URL path
path = urllib.parse.urlsplit(orig_url).path.rstrip('/')
base = path.split('/')[-1]
print(decode(base))
PY
}

# ---- aria2 queue file (for parallel non-GDrive downloads)
ARIA_INPUT_FILE=""   # created lazily

queue_aria() {
  local url="$1" dest_dir="$2" override="${3:-}"
  ensure_dir "$dest_dir"
  if [[ -z "$ARIA_INPUT_FILE" ]]; then
    ARIA_INPUT_FILE="$(mktemp)"
  fi

  local outname=""
  if [[ -n "$override" ]]; then
    outname="$override"
  else
    outname="$(detect_download_filename "$url" </dev/null || true)"
  fi

  {
    echo "$url"
    echo " dir=$dest_dir"
    if [[ -n "$outname" ]]; then
      echo " out=$outname"
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

# ---- run aria2 queue (or curl fallback) for non-GDrive items
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
      --retry-wait=2 --max-tries=5 \
      --console-log-level=warn \
      --summary-interval=0 \
      ${ARIA_EXTRA_FLAGS:-}
  else
    warn "aria2c not found; falling back to curl (serial)."
    # simple parser: URL line, then " dir=…" and optional " out=…"
    local url dir out
    url=""; dir=""; out=""
    while IFS= read -r line || [[ -n "$line" ]]; do
      if [[ "$line" == " "* ]]; then
        case "$line" in
          " dir="*) dir="${line# dir=}" ;;
          " out="*) out="${line# out=}" ;;
        esac
      else
        # if there was a previous URL pending, process it
        if [[ -n "$url" ]]; then
          mkdir -p "$dir"
          if [[ -n "$out" ]]; then
            curl -L --fail --retry 5 --retry-delay 2 -o "$dir/$out" "$url"
          else
            ( cd "$dir" && curl -L --fail --retry 5 --retry-delay 2 -J -O "$url" )
          fi
        fi
        # start a new block
        url="$line"; dir=""; out=""
      fi
    done < "$ARIA_INPUT_FILE"
    # process last block
    if [[ -n "$url" ]]; then
      mkdir -p "$dir"
      if [[ -n "$out" ]]; then
        curl -L --fail --retry 5 --retry-delay 2 -o "$dir/$out" "$url"
      else
        ( cd "$dir" && curl -L --fail --retry 5 --retry-delay 2 -J -O "$url" )
      fi
    fi
  fi

  rm -f "$ARIA_INPUT_FILE"
  ARIA_INPUT_FILE=""
}

download_to_bucket() {
  local prefix="$1" url="$2" override="${3:-}"
  local dest="${DEST_MAP[$prefix]:-}"

  if [[ -z "$dest" ]]; then
    # If not mapped, create a bucket matching the prefix
    dest="$COMFY_DIR/models/$prefix"
    warn "Unknown prefix '$prefix'; using $dest"
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