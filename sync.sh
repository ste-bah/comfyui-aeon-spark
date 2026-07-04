#!/usr/bin/env bash
# =============================================================================
# ComfyUI · AEON DGX Spark — incremental sync
#
# For users who already deployed and want to pull the latest:
#   - new bundled custom-node packs (via image pull)
#   - new pre-seeded workflows (via repo pull → seeded into volume on next boot)
#   - new auto-downloaded model files (via download_models.py update + re-run)
#
# Without losing anything they already installed via Manager, downloaded, or
# tweaked. The entrypoint's seeders are idempotent: they only ADD missing
# files, never overwrite or delete user content.
#
# Usage:
#   ./sync.sh                  # incremental update, prompts before model fetch
#   ./sync.sh --yes            # non-interactive (for agents / cron)
#   ./sync.sh --no-models      # only sync image + workflows + scripts, skip
#                              # model downloader (saves bandwidth if you
#                              # don't want new models yet)
#
# What it does, in order:
#   1. Pull the latest image from GHCR (any new bundled packs come this way)
#   2. Update local repo files (workflows/, download_models.py, scripts) —
#      via `git pull` if it's a git checkout, otherwise via shallow re-clone.
#   3. Show a diff summary: new/changed workflows, new model entries, deltas
#      in custom-node bundle.
#   4. Optionally prompt for confirmation.
#   5. Recreate the container — entrypoint seeds anything new without touching
#      your existing files.
#   6. Tail logs and surface the per-item Seeding / ⤓ / ✓ done lines so you can
#      see exactly what changed.
# =============================================================================
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"
ENV_FILE=".env"
COMPOSE_FILE="docker-compose.yml"
REPO_URL="https://github.com/AEON-7/comfyui-aeon-spark.git"

# ── ANSI ────────────────────────────────────────────────────────────────────
B=$'\033[1m'  D=$'\033[0m'
G=$'\033[1;32m'  Y=$'\033[1;33m'  R=$'\033[1;31m'  C=$'\033[1;36m'

# ── Args ────────────────────────────────────────────────────────────────────
YES=0; SKIP_MODELS=0
for arg in "$@"; do
  case "$arg" in
    --yes|-y) YES=1 ;;
    --no-models) SKIP_MODELS=1 ;;
    --help|-h)
      sed -n '4,30p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *)
      echo "${R}✗${D} Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

confirm() {
    [ "$YES" = "1" ] && return 0
    local reply; read -r -p "$1 [Y/n] " reply
    case "${reply:-Y}" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ── Pre-flight ──────────────────────────────────────────────────────────────
[ -f "$COMPOSE_FILE" ] || { echo "${R}✗${D} run from the deploy directory (where $COMPOSE_FILE lives)"; exit 1; }
[ -f "$ENV_FILE" ]    || { echo "${R}✗${D} no .env present — run ./setup.sh first"; exit 1; }

cat <<EOF
${B}╔════════════════════════════════════════════════════════════════╗
║       ComfyUI · AEON DGX Spark — Incremental Sync              ║
╚════════════════════════════════════════════════════════════════╝${D}

EOF

# ── Step 1: pull latest image ───────────────────────────────────────────────
. <(grep -E '^(IMAGE_TAG|COMFYUI_PORT)=' "$ENV_FILE" 2>/dev/null || true)
IMAGE_TAG="${IMAGE_TAG:-latest}"
IMAGE="ghcr.io/aeon-7/comfyui-aeon-spark:${IMAGE_TAG}"

echo "${C}━━━ 1/5: Pull latest image (${IMAGE_TAG}) ━━━${D}"
prev_image_id=$(docker images --no-trunc --format "{{.ID}}" "$IMAGE" 2>/dev/null | head -1)
docker compose pull comfyui ollama 2>&1 | tail -8
new_image_id=$(docker images --no-trunc --format "{{.ID}}" "$IMAGE" 2>/dev/null | head -1)
if [ "$prev_image_id" = "$new_image_id" ]; then
    echo "${G}✓${D} image already at latest digest"
else
    echo "${G}✓${D} image updated"
    echo "    was: ${prev_image_id:7:12}"
    echo "    now: ${new_image_id:7:12}"
fi

# ── Step 2: refresh local repo files (workflows/, scripts, downloader) ──────
echo
echo "${C}━━━ 2/5: Refresh local scripts & workflows from GitHub ━━━${D}"

# Pre-pull snapshots of the files that matter for diffing
mkdir -p .sync-old
cp -a workflows .sync-old/workflows 2>/dev/null || true
cp -a download_models.py .sync-old/download_models.py 2>/dev/null || true
cp -a models.yaml .sync-old/models.yaml 2>/dev/null || true

IS_GIT=0
if [ -d .git ]; then
    echo "  git checkout detected — running 'git pull --ff-only --autostash'"
    git fetch --quiet origin || true
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)

    # If untracked files would block the pull (e.g. sync.sh added later
    # in an old deploy), move them aside, pull, then drop the backup if
    # the pulled version supersedes them.
    if pull_out=$(git pull --ff-only --autostash --quiet origin "$BRANCH" 2>&1); then
        echo "${G}✓${D} repo fast-forwarded"
        IS_GIT=1
    else
        echo "${Y}⚠${D}  git pull failed:"
        echo "$pull_out" | sed 's/^/      /' | head -10
        # Try to recover: stash untracked, pull again
        if echo "$pull_out" | grep -q "untracked working tree files"; then
            echo "  retrying after moving conflicting untracked files aside…"
            mkdir -p .sync-quarantine
            # Extract the conflicting filenames from git's output
            blockers=$(echo "$pull_out" | sed -n '/^[[:space:]]*[A-Za-z0-9._/-]\+/p' | tr -d '\t' | sed 's/^[[:space:]]*//' | grep -E '\.(sh|py|json|md|yml)$' || true)
            for f in $blockers; do
                if [ -f "$f" ]; then
                    mkdir -p ".sync-quarantine/$(dirname "$f")" 2>/dev/null
                    mv "$f" ".sync-quarantine/$f" 2>/dev/null && echo "      quarantined: $f"
                fi
            done
            if git pull --ff-only --quiet origin "$BRANCH" 2>&1; then
                echo "${G}✓${D} repo fast-forwarded after quarantine"
                IS_GIT=1
            else
                echo "${R}✗${D} git pull still failing — falling back to snapshot fetch"
            fi
        fi
    fi
fi

if [ "$IS_GIT" = "0" ]; then
    echo "  no git repo here — fetching the runtime files from GitHub directly"
    TMPDIR=$(mktemp -d)
    git clone --depth=1 --quiet "$REPO_URL" "$TMPDIR/repo"
    for item in workflows download_models.py models.yaml setup.sh sync.sh; do
        if [ -e "$TMPDIR/repo/$item" ]; then
            rm -rf "./$item"
            cp -a "$TMPDIR/repo/$item" "./$item"
        fi
    done
    chmod +x setup.sh sync.sh 2>/dev/null || true
    rm -rf "$TMPDIR"
    echo "${G}✓${D} runtime files refreshed (workflows, download_models.py, models.yaml, setup.sh, sync.sh)"
fi

# ── Step 3: compute the diff ────────────────────────────────────────────────
echo
echo "${C}━━━ 3/5: Diff vs your current state ━━━${D}"

# 3a. New workflows (in repo but not yet in the user's volume)
WORKSPACE_WF="./workspace/user/default/workflows"
new_workflows=()
if [ -d workflows ] && [ -d "$WORKSPACE_WF" ]; then
    for f in workflows/*.json; do
        [ -e "$f" ] || continue
        name=$(basename "$f")
        # The volume has the workflow already if there's a file with the same name
        if [ ! -f "$WORKSPACE_WF/$name" ]; then
            new_workflows+=("$name")
        fi
    done
fi

# 3b. New download entries (lines in download_models.py that weren't in old version)
new_model_lines=()
if [ -f .sync-old/download_models.py ] && [ -f download_models.py ]; then
    while IFS= read -r line; do
        new_model_lines+=("$line")
    done < <(grep -F '"' download_models.py | grep -F '.safetensors' | \
             sort -u | comm -23 - <(grep -F '"' .sync-old/download_models.py | \
             grep -F '.safetensors' | sort -u))
fi

# 3c. Image change marker (we already detected new vs prev image_id above)
image_changed="no"
[ "$prev_image_id" != "$new_image_id" ] && image_changed="yes"

cat <<EOF
  ${B}Image:${D}        $([ "$image_changed" = "yes" ] && echo "${G}updated${D}" || echo "no change")
  ${B}Workflows:${D}    ${#new_workflows[@]} new
EOF
for w in "${new_workflows[@]}"; do echo "                ${G}+${D} $w"; done
echo "  ${B}Models:${D}       ${#new_model_lines[@]} new download entries"
for m in "${new_model_lines[@]:0:5}"; do
    fname=$(echo "$m" | grep -oE '[a-zA-Z0-9_./-]+\.safetensors' | head -1)
    echo "                ${G}+${D} ${fname:-$(echo $m | head -c 80)}"
done
[ "${#new_model_lines[@]}" -gt 5 ] && echo "                  ... and $((${#new_model_lines[@]} - 5)) more"

if [ "$image_changed" != "yes" ] && [ "${#new_workflows[@]}" = "0" ] && [ "${#new_model_lines[@]}" = "0" ]; then
    echo
    echo "${G}✓${D} you're already up-to-date — nothing to sync"
    rm -rf .sync-old
    exit 0
fi

# ── Step 4: confirm ─────────────────────────────────────────────────────────
echo
if [ "${#new_model_lines[@]}" -gt 0 ] && [ "$SKIP_MODELS" = "0" ]; then
    echo "${Y}⚠${D}  Recreating the container will trigger the model downloader."
    echo "   Files already on disk are skipped (idempotent), but the new"
    echo "   entries above WILL pull. Press Enter once you've reviewed."
    if ! confirm "Proceed?"; then
        echo "Aborted."; rm -rf .sync-old; exit 0
    fi
fi

# ── Step 5: recreate container ──────────────────────────────────────────────
echo
echo "${C}━━━ 4/5: Recreate container ━━━${D}"
if [ "$SKIP_MODELS" = "1" ]; then
    SKIP_MODEL_DOWNLOAD=1 docker compose up -d --force-recreate 2>&1 | tail -5
    echo "${G}✓${D} skipped model downloader (--no-models)"
else
    # The entrypoint short-circuits the downloader once the .models_seeded
    # sentinel exists (set after first-start). Without forcing it here, sync's
    # newly-pulled download_models.py entries silently never run on subsequent
    # boots — the bug that left the May 4 LTX 2.3 LoRAs unfetched on every
    # recreate. We explicitly force the downloader on every sync. The
    # downloader itself is idempotent (per-file basename check via huggingface_hub)
    # so already-present files skip in milliseconds while genuinely new
    # entries actually fetch.
    FORCE_MODEL_DOWNLOAD=1 docker compose up -d --force-recreate 2>&1 | tail -5
fi

# ── Step 6: stream the diff-relevant log lines ──────────────────────────────
echo
echo "${C}━━━ 5/5: Watching for new items to land ━━━${D}"
echo

# Wait up to 600s for ComfyUI to come back online
TIMEOUT=600
PORT="${COMFYUI_PORT:-8188}"
START=$(date +%s)

# Tail with --tail=500 to include the entrypoint history (seeding, downloads,
# launch line) — `-f` alone only shows lines AFTER the tail starts, so a fast
# launch can outrun us. We let the awk script exit on the launch marker, OR
# break out via timeout.
(
    docker compose logs --tail=500 -f comfyui 2>&1 | \
        grep -E --line-buffered "Seeding (custom node|workflow):|⤓ |✓ done:|download summary:|Launching ComfyUI" | \
        awk '
          /Seeding/             { printf "  + %s\n", $0; fflush(); next }
          /⤓/                   { printf "  ↓ %s\n", $0; fflush(); next }
          /✓ done/              { printf "  ✓ %s\n", $0; fflush(); next }
          /download summary/    { printf "  ∑ %s\n", $0; fflush(); next }
          /Launching ComfyUI/   { printf "  ▶ %s\n\n  ✓ ComfyUI launched\n", $0; fflush(); exit }
          { print; fflush() }
        '
) &
TAIL_PID=$!

# Independently poll readiness — if the API responds and the tail is still
# alive (because launch line was already in history pre-tail), kill it.
while kill -0 "$TAIL_PID" 2>/dev/null; do
    if [ $(( $(date +%s) - START )) -gt "$TIMEOUT" ]; then
        echo "${Y}⚠${D}  tail timed out after ${TIMEOUT}s — sync continues in background"
        kill "$TAIL_PID" 2>/dev/null
        break
    fi
    if curl -fsS -m 2 "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then
        # Give the awk pipe a beat to print any in-flight lines, then end
        sleep 1
        kill "$TAIL_PID" 2>/dev/null && echo "  ▶ ComfyUI is responding on port $PORT"
        break
    fi
    sleep 3
done
wait "$TAIL_PID" 2>/dev/null || true

cat <<EOF

${G}✓${D} Sync complete.
   - Volume preserved (your installed nodes / saved workflows untouched)
   - Open http://<spark-host>:${PORT} when you're ready
   - Check Manager → Install Queue if any new models are still downloading
EOF

rm -rf .sync-old
