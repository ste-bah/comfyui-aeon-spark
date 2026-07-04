#!/usr/bin/env bash
# =============================================================================
# ComfyUI · AEON DGX Spark — interactive setup
# Walks the user through HF token, license accepts, variant choice, launch.
# =============================================================================
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
ENV_FILE=".env"
COMPOSE_FILE="docker-compose.yml"

# ── ANSI ────────────────────────────────────────────────────────────────────
B=$'\033[1m'  D=$'\033[0m'
G=$'\033[1;32m'  Y=$'\033[1;33m'  R=$'\033[1;31m'  C=$'\033[1;36m'

banner() {
cat <<EOF
${B}╔════════════════════════════════════════════════════════════════╗
║       ComfyUI · AEON DGX Spark — Interactive Setup             ║
╚════════════════════════════════════════════════════════════════╝${D}

This script walks you through:
  ${B}1.${D} Setting up your HuggingFace access token
  ${B}2.${D} Accepting the gated-model licenses
  ${B}3.${D} Picking your image variant (auto-download vs no-download)
  ${B}4.${D} Launching the stack

Press ${B}Ctrl-C${D} at any time to abort.

EOF
}

prompt() {
    # $1 = prompt text, $2 = default
    local reply
    if [ -n "${2:-}" ]; then
        read -r -p "$1 [${2}] " reply
        echo "${reply:-$2}"
    else
        read -r -p "$1 " reply
        echo "$reply"
    fi
}

confirm() {
    # $1 = question, returns 0=yes, 1=no  (default Yes)
    local reply
    read -r -p "$1 [Y/n] " reply
    case "${reply:-Y}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ── Pre-flight ──────────────────────────────────────────────────────────────
if [ ! -f "$COMPOSE_FILE" ]; then
    echo "${R}✗${D} $COMPOSE_FILE not found. Run this script from the repo root." >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "${R}✗${D} docker not found in PATH. Install Docker first." >&2
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "${R}✗${D} docker compose plugin not found. Install Docker Compose plugin first." >&2
    exit 1
fi

if ! docker info 2>/dev/null | grep -q "Runtimes:.*nvidia"; then
    echo "${Y}⚠${D}  Docker doesn't have the nvidia runtime. The container will start but won't see the GPU."
    echo "   Install with: ${C}sudo apt install -y nvidia-container-toolkit && sudo systemctl restart docker${D}"
    if ! confirm "Continue anyway?"; then exit 1; fi
fi

banner

# ── Step 1: HuggingFace token ───────────────────────────────────────────────
existing_token=""
if [ -f "$ENV_FILE" ]; then
    existing_token=$(grep -E "^HF_TOKEN=" "$ENV_FILE" 2>/dev/null | head -1 | sed 's/^HF_TOKEN=//;s/^"//;s/"$//;s/^'\''//;s/'\''$//')
fi

# Treat the placeholder from .env.example as "no token"
if [[ "$existing_token" == hf_xxxxxxxxxxxxx* ]]; then existing_token=""; fi

token=""
if [ -n "$existing_token" ]; then
    masked="${existing_token:0:8}…${existing_token: -4}"
    echo "${G}✓${D} Found existing HF_TOKEN in .env (${masked})"
    if confirm "Use this token?"; then
        token="$existing_token"
    fi
fi

if [ -z "$token" ]; then
cat <<EOF

${C}━━━ Step 1: HuggingFace token ━━━${D}
This is needed to download model weights from HuggingFace under your account.
Each model's license is accepted by *you* on HuggingFace; this image never
acts as a redistributor.

  ${B}1.${D} If you don't have a HuggingFace account, sign up:
       ${C}https://huggingface.co/join${D}

  ${B}2.${D} Open: ${C}https://huggingface.co/settings/tokens${D}
  ${B}3.${D} Click ${B}"+ Create new token"${D}
  ${B}4.${D} Set ${B}Token type: Read${D}
  ${B}5.${D} Name it (e.g. "${B}dgx-spark${D}") and click Create
  ${B}6.${D} Copy the token (looks like ${C}hf_AbCd1234...${D})

EOF
    while true; do
        # -s hides the input so the token doesn't echo to the terminal/scrollback
        read -r -s -p "Paste your HF token here (input hidden, press Enter): " token
        echo
        if [ -z "$token" ]; then
            echo "${Y}⚠${D}  No token entered."
            if confirm "Continue without a token (you'll need to use :slim variant)?"; then
                token=""; break
            fi
            continue
        fi
        if [[ "$token" =~ ^hf_[A-Za-z0-9_]{20,}$ ]]; then
            echo "${G}✓${D} Token format looks valid (${token:0:8}…${token: -4})"
            break
        fi
        echo "${R}✗${D} That doesn't look like an HF token (should start with ${B}hf_${D} and be 20+ chars). Try again."
    done
fi

# ── Step 2: Gated repos ─────────────────────────────────────────────────────
cat <<EOF

${C}━━━ Step 2: Accept gated-model licenses ━━━${D}
Three Black Forest Labs repos require a one-time "Agree and access" click
under your HF account. Without this, those specific files return 403:

  ${B}1.${D} ${C}https://huggingface.co/black-forest-labs/FLUX.2-dev${D}
        (Flux 2 t2i — workflow 01)
  ${B}2.${D} ${C}https://huggingface.co/black-forest-labs/FLUX.2-klein-base-9b-fp8${D}
        (Flux 2 Klein 9B — workflow 08)
  ${B}3.${D} ${C}https://huggingface.co/black-forest-labs/FLUX.2-small-decoder${D}
        (Flux 2 VAE — workflows 01 + 08)

Open each URL → sign in → click ${B}"Agree and access repository"${D} → done.

(Other models — Mistral, Gemma, LTX 2.3, ACE-Step, Qwen — are not gated;
 your token can pull them right away.)

EOF
read -r -p "Have you accepted the licenses? [y/N/skip] " gated
case "${gated:-N}" in
    [Yy]*)  echo "${G}✓${D} OK — proceeding" ;;
    skip*)  echo "${Y}⚠${D}  Skipping — workflows 01 and 08 will fail to download until you accept" ;;
    *)      echo "${Y}⚠${D}  Not accepted yet — workflows 01 and 08 will 403. Accept later, then run:"
            echo "   ${C}rm workspace/.models_seeded && docker compose up -d --force-recreate${D}" ;;
esac

# ── Step 3: Image variant ───────────────────────────────────────────────────
cat <<EOF

${C}━━━ Step 3: Image variant ━━━${D}
  ${B}1) :latest${D}  (default — auto-downloads models on first start using your HF token;
                size set by the model profile you pick next: ~35–515 GB)
  ${B}2) :slim${D}    (no auto-download — pick each model via the in-UI Manager)

The slim variant is recommended if you don't have a token, want full control
over which models land on disk, or are working on a Spark with limited disk.
EOF

choice=$(prompt "Choice" "1")
case "$choice" in
    2|slim|s)   IMAGE_TAG="slim" ;;
    *)          IMAGE_TAG="latest" ;;
esac
echo "${G}✓${D} Selected: ${B}:${IMAGE_TAG}${D}"

# Warn if no token + :latest (won't be able to pull anything)
if [ -z "$token" ] && [ "$IMAGE_TAG" = "latest" ]; then
    echo "${Y}⚠${D}  You picked :latest but didn't provide a token — auto-download will 401 on every file."
    if confirm "Switch to :slim instead?"; then IMAGE_TAG="slim"; fi
fi

# ── Step 4: Port + abliterated snapshot toggle ──────────────────────────────
echo
PORT=$(prompt "Port for the ComfyUI web UI" "8188")
SKIP_ABLITERATED="0"
if [ "$IMAGE_TAG" = "latest" ]; then
    if confirm "Skip the optional ~70 GB huihui-ai abliterated full-LLM snapshots?"; then
        SKIP_ABLITERATED="1"
    fi
fi

# ── Step 4.5: Model profile (see models.yaml) ───────────────────────────────
MODEL_PROFILE="legacy"
if [ "$IMAGE_TAG" = "latest" ]; then
cat <<EOF

${C}━━━ Step 4.5: Model profile ━━━${D}
  ${B}1) spark${D}    (recommended on DGX Spark — NVFP4/FP8 only, no BF16 twins,
               plus Z-Image-Turbo + Qwen-Image, ~300 GB)
  ${B}2) legacy${D}   (original full set incl. BF16 variants, ~453 GB)
  ${B}3) latest${D}   (legacy + the 2026 additions, all precisions, ~515 GB)
  ${B}4) minimal${D}  (one model per modality, ~35 GB)

Run ${C}download_models.py --workspace ./workspace --profile <name> --list${D}
at any time to see the exact per-group plan. Add/remove groups later with
MODEL_GROUPS in .env (e.g. "+wan-video,-ace-audio").
EOF
    pchoice=$(prompt "Profile" "1")
    case "$pchoice" in
        2|legacy)   MODEL_PROFILE="legacy" ;;
        3|latest)   MODEL_PROFILE="latest" ;;
        4|minimal)  MODEL_PROFILE="minimal" ;;
        *)          MODEL_PROFILE="spark" ;;
    esac
    echo "${G}✓${D} Selected profile: ${B}${MODEL_PROFILE}${D}"
fi

# ── Step 5: Write .env ──────────────────────────────────────────────────────
cat > "$ENV_FILE" <<EOF
# Generated by setup.sh on $(date -Iseconds)
HF_TOKEN=$token
COMFYUI_PORT=$PORT
IMAGE_TAG=$IMAGE_TAG
SKIP_ABLITERATED=$SKIP_ABLITERATED
MODEL_PROFILE=$MODEL_PROFILE
EOF
chmod 600 "$ENV_FILE"
echo
echo "${G}✓${D} Wrote ${C}.env${D} (chmod 600 — token kept private to your user)"
echo
if [ -n "$token" ]; then
    echo "    HF_TOKEN          = ${token:0:8}…${token: -4}"
else
    echo "    HF_TOKEN          = (empty)"
fi
echo "    COMFYUI_PORT      = $PORT"
echo "    IMAGE_TAG         = $IMAGE_TAG"
echo "    SKIP_ABLITERATED  = $SKIP_ABLITERATED"
echo "    MODEL_PROFILE     = $MODEL_PROFILE"

# ── Step 6: Launch ──────────────────────────────────────────────────────────
echo
if confirm "Pull image and launch the stack now?"; then
    echo
    echo "${C}▶${D} docker compose pull"
    docker compose pull
    echo
    echo "${C}▶${D} docker compose up -d"
    docker compose up -d

    HOST=$(hostname -I 2>/dev/null | awk '{print $1}')
    [ -z "$HOST" ] && HOST="localhost"
    cat <<EOF

${G}╔════════════════════════════════════════════════════════════════╗
║  Stack started.                                                ║
╚════════════════════════════════════════════════════════════════╝${D}

Watch progress:    ${C}docker compose logs -f comfyui${D}

When you see ${B}'Launching ComfyUI on port $PORT'${D} (and on :latest, after
the model download finishes), open the UI at:
    ${C}http://$HOST:$PORT${D}

Workflow tips:
  - ${B}01_flux2_text_to_image${D}            — Flux 2 image gen (smallest, fastest)
  - ${B}02_ltx2.3_T2V_I2V_distilled${D}       — LTX 2.3 video, abliterated Gemma
  - ${B}09_acestep_ancient_sufi_xl${D}        — ACE-Step audio + Ollama prompt expansion

If a workflow says "missing models" — click ${B}Install Missing Models${D} in
the UI top bar.  Downloads land server-side in ${C}./workspace/models/${D},
never on the client browser (great for remote-accessed Sparks).

EOF
else
    echo
    echo "Launch later with: ${C}docker compose up -d${D}"
fi
