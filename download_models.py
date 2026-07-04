#!/usr/bin/env python
"""
Manifest-driven model downloader for comfyui-aeon-spark.

Models are declared in models.yaml (next to this script by default) with
group / precision / size metadata. Profiles select which subset to fetch:

    legacy   exact parity with the original 35-item set        (default)
    spark    DGX Spark optimal: NVFP4/FP8 first, no BF16 twins,
             plus the 2026 additions (Z-Image-Turbo, Qwen-Image)
    latest   legacy + 2026 additions, all precisions
    minimal  one model per modality, smallest footprint

Selection:
    --profile spark                (or env MODEL_PROFILE=spark)
    --groups "+wan-video,-ace-audio"   add/remove groups on top of a profile
                                   (or env MODEL_GROUPS=...)

Improvements over the original script:
    * preflight disk-space check (sum of pending sizes vs free space) —
      refuses to start a download that cannot fit; override with --force
    * post-download size verification against HF file metadata (catches
      truncated files the old "exists and size > 0" check waved through)
    * hardlink dedupe for files workflows expect under two names
    * --validate: check every selected entry exists on HF (metadata only,
      nothing downloaded) — use before enabling experimental groups
    * --list / --dry-run: show the plan and per-group sizes, do nothing
    * machine-readable manifest_status.json written into the workspace

Back-compat: --workspace and --skip-abliterated behave as before;
SKIP_ABLITERATED=1 is still honoured. Resume/idempotency semantics are
unchanged (files already present are skipped).
"""
from __future__ import annotations

import argparse
import json
import logging
import multiprocessing
import os
import shutil
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path

from huggingface_hub import hf_hub_download, snapshot_download
from huggingface_hub import get_hf_file_metadata, hf_hub_url
from huggingface_hub.utils import HfHubHTTPError

try:
    import yaml
except ImportError:  # pragma: no cover
    print("[downloader] PyYAML is required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

logging.basicConfig(
    format="\033[1;35m[downloader]\033[0m %(message)s",
    level=logging.INFO,
)
log = logging.getLogger("downloader")

os.environ.setdefault("HF_HUB_ENABLE_HF_TRANSFER", "1")
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "180")

DEFAULT_PROFILE = "legacy"
DISK_SAFETY_MARGIN_GB = 5.0   # kept free on top of the estimated download size
SIZE_TOLERANCE = 0.02         # 2% tolerance when comparing on-disk vs remote size

# Watchdog / progress knobs (seconds). The HF client's own timeout only guards
# connection setup; a transfer that goes silent mid-stream can hang forever.
# If no bytes move for STALL_TIMEOUT, the transfer is killed and retried.
STALL_TIMEOUT = float(os.environ.get("DOWNLOAD_STALL_TIMEOUT", "180"))   # 0 disables
PROGRESS_INTERVAL = float(os.environ.get("DOWNLOAD_PROGRESS_INTERVAL", "30"))
_WATCH_POLL = 5.0


class DownloadStalled(OSError):
    """Transfer made no progress for STALL_TIMEOUT seconds (retryable)."""


def _hf_cache_dir() -> Path:
    return Path(os.environ.get("HF_HOME", str(Path.home() / ".cache" / "huggingface")))


def _tree_bytes(paths: list[Path]) -> int:
    total = 0
    for root in paths:
        try:
            if not root.exists():
                continue
            for f in root.rglob("*"):
                try:
                    if f.is_file():
                        total += f.stat().st_size
                except OSError:
                    continue
        except OSError:
            continue
    return total


def _child_hf_download(repo_id: str, filename: str, local_dir: str,
                       token: str | None) -> None:  # pragma: no cover (subprocess)
    hf_hub_download(repo_id=repo_id, filename=filename,
                    local_dir=local_dir, token=token)


def _child_snapshot(repo_id: str, local_dir: str, allow_patterns: list[str],
                    token: str | None) -> None:  # pragma: no cover (subprocess)
    snapshot_download(repo_id=repo_id, local_dir=local_dir,
                      allow_patterns=allow_patterns, token=token)


def _run_guarded(target, args: tuple, watch_paths: list[Path], name: str,
                 expected_gb: float = 0.0) -> None:
    """Run a download in a subprocess with a stall watchdog + progress log.

    Bytes are measured across watch_paths (destination dir + HF cache, which
    covers Xet-staged transfers). No byte movement for STALL_TIMEOUT seconds
    -> the subprocess is killed and DownloadStalled raised, which the retry
    wrapper treats like any transient failure.
    """
    if STALL_TIMEOUT <= 0:
        target(*args)
        return
    proc = multiprocessing.Process(target=target, args=args, daemon=True)
    proc.start()
    baseline = _tree_bytes(watch_paths)
    prev = baseline
    log_ref = baseline
    now0 = time.monotonic()
    last_change = last_log = now0
    while proc.is_alive():
        proc.join(timeout=_WATCH_POLL)
        if not proc.is_alive():
            break
        now = time.monotonic()
        cur = _tree_bytes(watch_paths)
        if cur != prev:
            last_change = now
        prev = cur
        if now - last_log >= PROGRESS_INTERVAL:
            done_gb = max(cur - baseline, 0) / 1e9
            rate_mb = max(cur - log_ref, 0) / max(now - last_log, 1.0) / 1e6
            pct = f", ~{min(100.0, 100.0 * done_gb / expected_gb):.0f}%" if expected_gb else ""
            log.info("… %s: %.2f GB transferred%s (%.0f MB/s)", name, done_gb, pct, rate_mb)
            log_ref, last_log = cur, now
        if now - last_change > STALL_TIMEOUT:
            log.warning("no data for %.0fs on %s — killing transfer for retry",
                        STALL_TIMEOUT, name)
            proc.terminate()
            proc.join(10)
            if proc.is_alive():
                proc.kill()
                proc.join(5)
            raise DownloadStalled(f"transfer stalled: {name}")
    if proc.exitcode not in (0, None):
        raise OSError(f"download subprocess for {name} exited with code {proc.exitcode}")


# ---------------------------------------------------------------------------
# Manifest model
# ---------------------------------------------------------------------------
@dataclass
class Entry:
    dest: str
    name: str
    size_gb: float
    precision: str
    group: str
    repo: str | None = None
    file: str | None = None
    rename: str | None = None
    gated: bool = False
    link_of: str | None = None

    @property
    def target_name(self) -> str:
        if self.rename:
            return self.rename
        if self.file:
            return Path(self.file).name
        return Path(self.link_of or "unknown").name

    def target_path(self, models_dir: Path) -> Path:
        return models_dir / self.dest / self.target_name


@dataclass
class Snapshot:
    repo: str
    dest: str
    name: str
    size_gb: float
    group: str
    allow_patterns: list[str] = field(default_factory=list)


def load_manifest(path: Path) -> tuple[list[Entry], list[Snapshot], dict]:
    with path.open() as fh:
        data = yaml.safe_load(fh)
    if not isinstance(data, dict) or data.get("schema") != 1:
        raise SystemExit(f"unsupported or missing manifest schema in {path}")
    entries = [Entry(**e) for e in data.get("entries", [])]
    snapshots = [Snapshot(**s) for s in data.get("snapshots", [])]
    profiles = data.get("profiles", {})
    return entries, snapshots, profiles


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------
def parse_group_mods(spec: str) -> tuple[set[str], set[str]]:
    """'+wan-video,-ace-audio' -> (add={'wan-video'}, remove={'ace-audio'})"""
    add, remove = set(), set()
    for tok in filter(None, (t.strip() for t in spec.split(","))):
        if tok.startswith("-"):
            remove.add(tok[1:])
        else:
            add.add(tok.lstrip("+"))
    return add, remove


def select(entries: list[Entry], snapshots: list[Snapshot], profiles: dict,
           profile_name: str, group_spec: str, skip_abliterated: bool
           ) -> tuple[list[Entry], list[Snapshot], set[str]]:
    if profile_name not in profiles:
        raise SystemExit(
            f"unknown profile '{profile_name}' (available: {', '.join(sorted(profiles))})")
    prof = profiles[profile_name]
    groups = set(prof.get("groups", []))
    excluded_precisions = set(prof.get("exclude_precisions", []))

    add, remove = parse_group_mods(group_spec)
    groups |= add
    groups -= remove
    if skip_abliterated:
        groups.discard("abliterated")

    picked = [e for e in entries
              if e.group in groups and e.precision not in excluded_precisions]
    picked_snaps = [s for s in snapshots if s.group in groups]

    # A hardlink whose source file was excluded by the precision filter can
    # never be created — drop it and say so.
    targets = {f"{e.dest}/{e.target_name}" for e in picked if not e.link_of}
    kept = []
    for e in picked:
        if e.link_of and e.link_of not in targets:
            log.info("~ skipping %s (link source excluded by profile)", e.name)
            continue
        kept.append(e)
    return kept, picked_snaps, groups


# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
def pending_size_gb(entries: list[Entry], snapshots: list[Snapshot],
                    models_dir: Path) -> float:
    total = 0.0
    for e in entries:
        if e.link_of:
            continue
        p = e.target_path(models_dir)
        if not (p.exists() and p.stat().st_size > 0):
            total += e.size_gb
    for s in snapshots:
        d = models_dir / "text_encoders" / s.dest
        if not (d.exists() and any(d.glob("*.safetensors"))):
            total += s.size_gb
    return total


def preflight_disk(models_dir: Path, needed_gb: float, force: bool) -> None:
    models_dir.mkdir(parents=True, exist_ok=True)
    free_gb = shutil.disk_usage(models_dir).free / 1e9
    required = needed_gb + DISK_SAFETY_MARGIN_GB
    log.info("preflight: ~%.1f GB to download, %.1f GB free (margin %.0f GB)",
             needed_gb, free_gb, DISK_SAFETY_MARGIN_GB)
    if free_gb < required:
        msg = (f"insufficient disk: need ~{required:.0f} GB free on "
               f"{models_dir}, have {free_gb:.0f} GB. Free space, choose a "
               f"smaller profile (MODEL_PROFILE=spark|minimal), or move the "
               f"workspace (COMFY_WORKSPACE) to a larger volume.")
        if force:
            log.warning("%s -- continuing anyway (--force)", msg)
        else:
            raise SystemExit(f"[downloader] {msg} (use --force to override)")


# ---------------------------------------------------------------------------
# Fetch / verify / link
# ---------------------------------------------------------------------------
def _retry(callable_, *, attempts: int = 4, base_delay: float = 5.0):
    last = None
    for i in range(attempts):
        try:
            return callable_()
        except (HfHubHTTPError, ConnectionError, OSError) as e:
            last = e
            wait = base_delay * (2 ** i)
            log.warning("attempt %d/%d failed (%s); retrying in %.0fs",
                        i + 1, attempts, e, wait)
            time.sleep(wait)
    raise last  # type: ignore[misc]


def remote_size(entry: Entry, token: str | None) -> int | None:
    """Size in bytes from HF metadata, or None if unavailable."""
    try:
        url = hf_hub_url(repo_id=entry.repo, filename=entry.file)
        meta = get_hf_file_metadata(url, token=token)
        return meta.size
    except Exception:
        return None


def verify_size(path: Path, expected: int | None, friendly: str) -> bool:
    if expected is None:
        return True  # metadata unavailable; don't fail the download over it
    actual = path.stat().st_size
    if abs(actual - expected) <= expected * SIZE_TOLERANCE:
        return True
    log.error("✗ size mismatch for %s: on disk %d bytes, HF reports %d — "
              "removing corrupt file", friendly, actual, expected)
    path.unlink(missing_ok=True)
    return False


def fetch_entry(entry: Entry, models_dir: Path, token: str | None) -> bool:
    dst_dir = models_dir / entry.dest
    final_path = entry.target_path(models_dir)

    if final_path.exists() and final_path.stat().st_size > 0:
        log.info("✓ already present: %s", entry.name)
        return True

    # Hardlink entries: link to an already-downloaded sibling.
    if entry.link_of:
        src = models_dir / entry.link_of
        if not (src.exists() and src.stat().st_size > 0):
            log.error("✗ link source missing for %s (%s)", entry.name, src)
            return False
        final_path.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.link(src, final_path)
            log.info("✓ hardlinked: %s -> %s", entry.name, final_path)
        except OSError:
            shutil.copy2(src, final_path)
            log.info("✓ copied (fs does not support hardlinks): %s", entry.name)
        return True

    log.info("⤓ %s  (%s :: %s%s)", entry.name, entry.repo, entry.file,
             f"  → renamed to {entry.target_name}" if entry.rename else "")
    dst_dir.mkdir(parents=True, exist_ok=True)
    try:
        _retry(lambda: _run_guarded(
            _child_hf_download,
            (entry.repo, entry.file, str(dst_dir), token),
            [dst_dir, _hf_cache_dir()],
            entry.name,
            entry.size_gb,
        ))
        # hf_hub_download(local_dir=...) writes to local_dir/<repo filepath>
        out_path = dst_dir / entry.file
        # Flatten any HF-imposed subfolder (split_files/...) and apply rename
        if out_path != final_path and out_path.exists():
            final_path.parent.mkdir(parents=True, exist_ok=True)
            try:
                out_path.replace(final_path)
            except OSError:
                shutil.copy2(out_path, final_path)
                out_path.unlink(missing_ok=True)
            try:
                parent = out_path.parent
                while parent != dst_dir and not any(parent.iterdir()):
                    parent.rmdir()
                    parent = parent.parent
            except OSError:
                pass
        if not verify_size(final_path, remote_size(entry, token), entry.name):
            return False
        log.info("✓ done: %s -> %s", entry.name, final_path)
        return True
    except Exception as e:
        hint = " (gated repo — accept the licence on HF and set HF_TOKEN)" \
            if entry.gated and "403" in str(e) else ""
        log.error("✗ failed: %s (%s)%s", entry.name, e, hint)
        return False


def fetch_snapshot(s: Snapshot, models_dir: Path, token: str | None) -> bool:
    dst_dir = models_dir / "text_encoders" / s.dest
    if dst_dir.exists() and any(dst_dir.glob("*.safetensors")):
        log.info("✓ snapshot already present: %s", s.name)
        return True
    log.info("⤓ snapshot %s  (%s)", s.name, s.repo)
    dst_dir.mkdir(parents=True, exist_ok=True)
    try:
        _retry(lambda: _run_guarded(
            _child_snapshot,
            (s.repo, str(dst_dir), list(s.allow_patterns), token),
            [dst_dir, _hf_cache_dir()],
            s.name,
            s.size_gb,
        ))
        log.info("✓ done snapshot: %s -> %s", s.name, dst_dir)
        return True
    except Exception as e:
        log.error("✗ snapshot failed: %s (%s)", s.name, e)
        return False


# ---------------------------------------------------------------------------
# Reporting modes
# ---------------------------------------------------------------------------
def print_plan(entries: list[Entry], snapshots: list[Snapshot],
               models_dir: Path) -> None:
    by_group: dict[str, float] = {}
    for e in entries:
        p = e.target_path(models_dir)
        state = "present" if p.exists() and p.stat().st_size > 0 else \
                ("link" if e.link_of else "fetch")
        log.info("  [%-7s] %-11s %5.1f GB  %s", state, e.group, e.size_gb, e.name)
        if state == "fetch":
            by_group[e.group] = by_group.get(e.group, 0.0) + e.size_gb
    for s in snapshots:
        d = models_dir / "text_encoders" / s.dest
        state = "present" if d.exists() and any(d.glob("*.safetensors")) else "fetch"
        log.info("  [%-7s] %-11s %5.1f GB  %s", state, s.group, s.size_gb, s.name)
        if state == "fetch":
            by_group[s.group] = by_group.get(s.group, 0.0) + s.size_gb
    log.info("-" * 60)
    for g in sorted(by_group):
        log.info("  to fetch — %-12s %6.1f GB", g, by_group[g])
    log.info("  to fetch — TOTAL        %6.1f GB", sum(by_group.values()))


def validate(entries: list[Entry], token: str | None) -> int:
    """Metadata-only existence/size check. Returns number of failures."""
    failures = 0
    for e in entries:
        if e.link_of:
            continue
        size = remote_size(e, token)
        if size is None:
            log.error("✗ NOT FOUND on HF: %s  (%s :: %s)", e.name, e.repo, e.file)
            failures += 1
        else:
            drift = ""
            if e.size_gb and abs(size / 1e9 - e.size_gb) > max(1.0, e.size_gb * 0.25):
                drift = f"  [manifest says {e.size_gb:.1f} GB — update size_gb]"
            log.info("✓ %s — %.2f GB on HF%s", e.name, size / 1e9, drift)
    return failures


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--workspace", required=True,
                        help="Persistent workspace root (parent of models/)")
    parser.add_argument("--manifest", default=None,
                        help="Path to models.yaml (default: next to this script, "
                             "then <workspace>/models.yaml)")
    parser.add_argument("--profile", default=os.environ.get("MODEL_PROFILE", DEFAULT_PROFILE),
                        help=f"Selection profile (default: env MODEL_PROFILE or '{DEFAULT_PROFILE}')")
    parser.add_argument("--groups", default=os.environ.get("MODEL_GROUPS", ""),
                        help="Comma-separated group modifiers, e.g. '+wan-video,-ace-audio' "
                             "(default: env MODEL_GROUPS)")
    parser.add_argument("--skip-abliterated", action="store_true",
                        help="Skip the abliterated LLM snapshots (back-compat)")
    parser.add_argument("--list", action="store_true",
                        help="Show the selection plan with sizes and exit")
    parser.add_argument("--dry-run", action="store_true",
                        help="Alias for --list")
    parser.add_argument("--validate", action="store_true",
                        help="Check selected entries exist on HF (metadata only) and exit")
    parser.add_argument("--force", action="store_true",
                        help="Proceed even if the preflight disk check fails")
    args = parser.parse_args()

    ws = Path(args.workspace)
    models_dir = ws / "models"

    manifest_path = None
    for candidate in ([Path(args.manifest)] if args.manifest else
                      [Path(__file__).parent / "models.yaml", ws / "models.yaml"]):
        if candidate.exists():
            manifest_path = candidate
            break
    if manifest_path is None:
        log.error("models.yaml not found (looked next to the script and in the workspace)")
        return 2
    log.info("manifest: %s", manifest_path)

    entries, snapshots, profiles = load_manifest(manifest_path)

    skip_abl = args.skip_abliterated or os.environ.get("SKIP_ABLITERATED", "0") == "1"
    sel_entries, sel_snaps, groups = select(
        entries, snapshots, profiles, args.profile, args.groups, skip_abl)
    log.info("profile: %s   groups: %s", args.profile, ", ".join(sorted(groups)))
    if STALL_TIMEOUT > 0:
        log.info("stall watchdog: %.0fs, progress every %.0fs "
                 "(DOWNLOAD_STALL_TIMEOUT / DOWNLOAD_PROGRESS_INTERVAL to tune)",
                 STALL_TIMEOUT, PROGRESS_INTERVAL)

    token = os.environ.get("HF_TOKEN") or os.environ.get("HUGGING_FACE_HUB_TOKEN")
    if token:
        log.info("HF token detected — gated repos accessible")
    else:
        log.warning("no HF_TOKEN set — gated repos (FLUX.2-dev, Klein, Gemma) may fail")

    if args.list or args.dry_run:
        print_plan(sel_entries, sel_snaps, models_dir)
        return 0

    if args.validate:
        failures = validate(sel_entries, token)
        log.info("validate: %d entries checked, %d missing",
                 len([e for e in sel_entries if not e.link_of]), failures)
        return 0 if failures == 0 else 1

    needed = pending_size_gb(sel_entries, sel_snaps, models_dir)
    preflight_disk(models_dir, needed, args.force)

    status: dict = {"profile": args.profile, "groups": sorted(groups),
                    "manifest": str(manifest_path), "entries": []}
    successes = failures = 0

    # Non-link entries first so hardlink sources exist before links are made.
    for e in sorted(sel_entries, key=lambda x: bool(x.link_of)):
        ok = fetch_entry(e, models_dir, token)
        successes += int(ok)
        failures += int(not ok)
        status["entries"].append({
            "name": e.name, "group": e.group,
            "path": str(e.target_path(models_dir)), "ok": ok,
        })

    for s in sel_snaps:
        ok = fetch_snapshot(s, models_dir, token)
        successes += int(ok)
        failures += int(not ok)
        status["entries"].append({"name": s.name, "group": s.group,
                                  "snapshot": True, "ok": ok})

    status["ok"] = successes
    status["failed"] = failures
    try:
        (ws / "manifest_status.json").write_text(json.dumps(status, indent=2))
    except OSError as e:
        log.warning("could not write manifest_status.json (%s)", e)

    log.info("=" * 60)
    log.info("download summary: %d ok, %d failed", successes, failures)
    log.info("=" * 60)
    return 0 if failures == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
