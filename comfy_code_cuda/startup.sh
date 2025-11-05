#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ---------- CONFIG ----------
COMFY_DIR=/workspace/ComfyUI
CUSTOM_NODES_DIR="$COMFY_DIR/custom_nodes"
WORKFLOWS_DIR="$COMFY_DIR/user/default/workflows"
VENV_DIR=/workspace/venv
COMFY_PORT=8188
CODE_PORT=8443
CODE_PASS="${CODE_SERVER_PASSWORD:-}"
WORKFLOW_REPO="${WORKFLOW_REPO:-}"         # e.g. https://github.com/you/comfy-profiles.git
WORKFLOW_PROFILE="${WORKFLOW_PROFILE:-}"   # e.g. img2vid
MODEL_CONCURRENCY="${MODEL_CONCURRENCY:-8}"

echo "[info] Bootstrapping environment…"
apt-get update -y
apt-get install -y --no-install-recommends \
  git curl wget ca-certificates python3 python3-venv python3-pip \
  aria2 unzip tar openssl build-essential
apt-get clean && rm -rf /var/lib/apt/lists/*

# ---------- ComfyUI ----------
if [ ! -d "$COMFY_DIR" ]; then
  echo "[info] Cloning ComfyUI…"
  git clone --depth=1 https://github.com/comfyanonymous/ComfyUI.git "$COMFY_DIR"
fi

# Python venv
if [ ! -d "$VENV_DIR" ]; then
  python3 -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"
pip install --upgrade pip wheel setuptools

# ---------- Detect CUDA + install matching torch ----------
echo "[info] Detecting CUDA version…"
CUDA_VERSION="$(nvcc --version 2>/dev/null | grep 'release' | sed -E 's/.*release ([0-9]+\.[0-9]+).*/\1/')"
if [ -z "${CUDA_VERSION:-}" ]; then
  CUDA_VERSION="$(cat /usr/local/cuda/version.txt 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+')" || true
fi

TORCH_URL=""
case "$CUDA_VERSION" in
  12.*) TORCH_URL="https://download.pytorch.org/whl/cu121" ;;
  11.*) TORCH_URL="https://download.pytorch.org/whl/cu118" ;;
  *) TORCH_URL="https://download.pytorch.org/whl/cpu" ;;
esac

echo "[info] Installing torch for CUDA ${CUDA_VERSION:-CPU} from $TORCH_URL"
pip install torch torchvision torchaudio --index-url "$TORCH_URL" || \
  echo "[warn] Torch install failed — continuing anyway"

# ---------- Install ComfyUI requirements ----------
echo "[info] Installing ComfyUI dependencies (log: /workspace/pip-install.log)…"
pip install -r "$COMFY_DIR/requirements.txt" > /workspace/pip-install.log 2>&1 || \
  echo "[warn] Some dependencies failed; see /workspace/pip-install.log"

# ---------- ComfyUI Manager ----------
mkdir -p "$CUSTOM_NODES_DIR"
if [ ! -d "$CUSTOM_NODES_DIR/ComfyUI-Manager" ]; then
  echo "[info] Installing ComfyUI-Manager…"
  git clone --depth=1 https://github.com/ltdrdata/ComfyUI-Manager "$CUSTOM_NODES_DIR/ComfyUI-Manager"
fi
pip install -r "$CUSTOM_NODES_DIR/ComfyUI-Manager/requirements.txt" || true

# ---------- VS Code (code-server) ----------
if ! command -v code-server >/dev/null 2>&1; then
  echo "[info] Installing code-server…"
  curl -fsSL https://code-server.dev/install.sh | sh || { echo "[error] code-server install failed"; exit 1; }
fi
if [ -z "$CODE_PASS" ]; then
  CODE_PASS="$(openssl rand -hex 12)"
  echo "[warn] CODE_SERVER_PASSWORD not set. Temporary password: $CODE_PASS"
fi
mkdir -p /root/.config/code-server
cat >/root/.config/code-server/config.yaml <<EOF
bind-addr: 0.0.0.0:${CODE_PORT}
auth: password
password: ${CODE_PASS}
cert: false
EOF
nohup code-server /workspace --log debug >/workspace/code-server.log 2>&1 &
sleep 2  # Give code-server time to start

# ---------- Pull workflow profile ----------
PROFILE_ROOT=/workspace/_profiles
mkdir -p "$PROFILE_ROOT"

if [[ "$WORKFLOW_REPO" =~ \.git$ ]]; then
  echo "[info] Cloning Git repo: $WORKFLOW_REPO"
  AUTH_REPO="$WORKFLOW_REPO"
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    AUTH_REPO="https://${GITHUB_TOKEN}@${WORKFLOW_REPO#https://}"
  fi
  if [ ! -d "$PROFILE_ROOT/.git" ]; then
    git clone --depth=1 "$AUTH_REPO" "$PROFILE_ROOT"
  else
    git -C "$PROFILE_ROOT" fetch --depth=1 origin main || git -C "$PROFILE_ROOT" fetch --depth=1 origin master
    git -C "$PROFILE_ROOT" reset --hard FETCH_HEAD
  fi
elif [ -n "$WORKFLOW_REPO" ]; then
  mkdir -p /workspace/_dl && cd /workspace/_dl
  if curl -fsSL "$WORKFLOW_REPO" -o bundle; then
    echo "[info] Downloaded archive bundle; extracting..."
    rm -rf "$PROFILE_ROOT" && mkdir -p "$PROFILE_ROOT"
    if file bundle | grep -qi zip; then
      unzip -q bundle -d "$PROFILE_ROOT"
    else
      tar -xf bundle -C "$PROFILE_ROOT"
    fi
  else
    echo "[warn] Could not download WORKFLOW_REPO; skipping."
  fi
fi

# Resolve profile path
PROFILE_PATH=""
if [ -n "$WORKFLOW_PROFILE" ] && [ -d "$PROFILE_ROOT" ]; then
  if [ -d "$PROFILE_ROOT/$WORKFLOW_PROFILE" ]; then
    PROFILE_PATH="$PROFILE_ROOT/$WORKFLOW_PROFILE"
  else
    CANDIDATE="$(find "$PROFILE_ROOT" -maxdepth 2 -type d -name "$WORKFLOW_PROFILE" | head -n1 || true)"
    [ -n "$CANDIDATE" ] && PROFILE_PATH="$CANDIDATE"
  fi
fi

# Model folder mapping
CKPT_DIR="$COMFY_DIR/models/checkpoints"
DIFF_DIR="$COMFY_DIR/models/diffusion_models"
LORA_DIR="$COMFY_DIR/models/loras"
VAE_DIR="$COMFY_DIR/models/vae"
TXTE_DIR="$COMFY_DIR/models/text_encoders"

# ---------- Install workflow + download models ----------
mkdir -p "$WORKFLOWS_DIR" "$CKPT_DIR" "$DIFF_DIR" "$LORA_DIR" "$VAE_DIR" "$TXTE_DIR"

if [ -n "$PROFILE_PATH" ] && [ -d "$PROFILE_PATH" ]; then
  echo "[info] Using profile at: $PROFILE_PATH"

  find "$PROFILE_PATH" -maxdepth 1 -type f \( -iname '*.json' -o -iname '*.workflow' \) -print0 | \
    xargs -0 -I{} cp -f "{}" "$WORKFLOWS_DIR" || true

  download_list() {
    local list_file="$1"; shift
    local dest_dir="$1"; shift
    [ -f "$list_file" ] || return 0
    mkdir -p "$dest_dir"
    echo "[info] Downloading models from $(basename "$list_file") → $dest_dir"
    aria2c -x"$MODEL_CONCURRENCY" -s"$MODEL_CONCURRENCY" \
           --allow-overwrite=true --continue=true \
           --content-disposition-default-utf8=true --content-disposition=true \
           --auto-file-renaming=false --max-tries=3 --retry-wait=2 \
           --input-file="$list_file" --dir="$dest_dir" || true
  }

  download_list "$PROFILE_PATH/models_checkpoints.txt" "$CKPT_DIR"
  download_list "$PROFILE_PATH/models_diffusion_models.txt" "$DIFF_DIR"
  download_list "$PROFILE_PATH/models_loras.txt" "$LORA_DIR"
  download_list "$PROFILE_PATH/models_vae.txt" "$VAE_DIR"
  download_list "$PROFILE_PATH/models_text_encoders.txt" "$TXTE_DIR"

  if [ -x "$PROFILE_PATH/post.sh" ]; then
    echo "[info] Running post.sh…"
    (set -e; cd "$PROFILE_PATH" && bash ./post.sh) || echo "[warn] post.sh exited non-zero."
  fi
else
  echo "[info] No profile folder found; you can still upload a workflow in VS Code."
fi

# ---- Google Drive LORAs ----
set -Eeuo pipefail

LORA_DIR="/workspace/ComfyUI/models/loras"
LIST_FILE="models_loras_gdrive.txt"

# install gdown if it's not present
if ! command -v gdown >/dev/null 2>&1; then
  python3 -m pip install -q --no-cache-dir gdown
fi

mkdir -p "$LORA_DIR"

# If the list file doesn't exist or is empty, just skip
if [[ -s "$LIST_FILE" ]]; then
  # Each non-empty, non-comment line can be:
  #   1) a full Drive URL (share link or uc?id=...)
  #   2) a full Drive URL followed by "out=filename"
  #   3) a bare FILE_ID (optional) and optional "out=filename"
  #
  # Examples in models_loras_gdrive.txt:
  #   https://drive.google.com/file/d/1WJ4oRBlpJqj_Qn83lLdZxurF--zz0qxO/view?usp=share
  #   https://drive.google.com/uc?id=1WJ4oRBlpJqj_Qn83lLdZxurF--zz0qxO out=LoRA_umt5_xxl.safetensors
  #   1WJ4oRBlpJqj_Qn83lLdZxurF--zz0qxO out=my_lora.safetensors

  while IFS= read -r raw || [[ -n "$raw" ]]; do
    # skip comments/blank lines
    [[ -z "${raw//[[:space:]]/}" || "$raw" =~ ^[[:space:]]*# ]] && continue

    url_or_id=$(awk '{print $1}' <<<"$raw")
    # optional out=filename token anywhere on the line
    out_name=$(grep -oE 'out=[^[:space:]]+' <<<"$raw" | sed 's/^out=//') || true

    # Decide whether we have an ID or a URL
    if [[ "$url_or_id" =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
      # bare FILE_ID
      if [[ -n "$out_name" ]]; then
        gdown --retries 3 --timeout 30 --id "$url_or_id" -O "$LORA_DIR/$out_name"
      else
        # Put into directory to preserve the Drive filename
        gdown --retries 3 --timeout 30 --id "$url_or_id" -O "$LORA_DIR/"
      fi
    else
      # URL (share link or uc?id=...), let gdown resolve it
      if [[ -n "$out_name" ]]; then
        gdown --fuzzy --retries 3 --timeout 30 "$url_or_id" -O "$LORA_DIR/$out_name"
      else
        gdown --fuzzy --retries 3 --timeout 30 "$url_or_id" -O "$LORA_DIR/"
      fi
    fi
  done < "$LIST_FILE"
fi
# ---- end Google Drive LORAs ----

# ---------- Health Check / Summary ----------
PUBLIC_IP="$(curl -s ifconfig.me || echo '0.0.0.0')"
echo
echo "==============================================================="
echo "✅ Setup complete!"
echo
echo "🌐 ComfyUI:  http://${PUBLIC_IP}:${COMFY_PORT}"
echo "💻 VS Code:   http://${PUBLIC_IP}:${CODE_PORT}"
echo "🔑 VS Code password: ${CODE_PASS}"
echo
if [ -n "$WORKFLOW_REPO" ]; then
  echo "📦 Workflow repo: ${WORKFLOW_REPO}"
  [ -n "$WORKFLOW_PROFILE" ] && echo "🧩 Active profile: ${WORKFLOW_PROFILE}"
fi
echo
echo "📂 Workspace: /workspace"
echo "🧠 Python venv: ${VENV_DIR}"
echo "==============================================================="
echo

# ---------- Launch ComfyUI ----------
echo "[info] Starting ComfyUI on 0.0.0.0:${COMFY_PORT}"
cd "$COMFY_DIR"
exec /usr/bin/env python3 main.py --listen 0.0.0.0 --port "$COMFY_PORT"
