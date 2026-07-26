#!/bin/bash
# v2026.07.26
# Author: Lazaros Chalkidis
set -euo pipefail
IFS=$'\n\t'

renice -n 15 -p $$ >/dev/null 2>&1 || true
ionice -c2 -n7 -p $$ >/dev/null 2>&1 || true

echo "=== STARTING SRT RENAME: .gre.srt -> .ell.srt ==="

# scanned per volume, not through shfs
MNT="/mnt"
SUBROOTS=(
  "Media/Movies"
  "Media/TV Shows"
)

# not real storage
VOL_SKIP="user user0 disks remotes addons rootshare"

LOG="/mnt/user/appdata/srt_rename_gre_to_ell.log"
STATE="/mnt/user/appdata/srt_rename_gre_to_ell.last_run"
SUCCESS_MARK="/mnt/user/appdata/srt_rename_gre_to_ell.last_success"

DRY_RUN=0
FORCE=0
FULL=1
DEDUPE=0
DROP_CACHES=0
HEARTBEAT_SECS=60
LOG_MAX_LINES=5000

while [[ $# -gt 0 ]]; do
  arg="${1//$'\r'/}"
  case "$arg" in
    "") shift ;;
    --dry-run)     DRY_RUN=1; shift ;;
    --force)       FORCE=1; shift ;;
    --full)        FULL=1; shift ;;
    --inc)         FULL=0; shift ;;
    --dedupe)      DEDUPE=1; shift ;;
    --drop-caches) DROP_CACHES=1; shift ;;
    --wake|--nowake) DEPRECATED_ARG="$arg"; shift ;;
    *) echo "Unknown option: [$(printf '%q' "$arg")]"; exit 1 ;;
  esac
done

# --force overwrites the target, --dedupe deletes the source, never both
if [[ $DEDUPE -eq 1 && $FORCE -eq 1 ]]; then
  echo "ABORT: --dedupe and --force are mutually exclusive."
  exit 1
fi

mkdir -p "$(dirname "$LOG")"

if [[ -f "$LOG" ]]; then
  tmp_log="$(mktemp)"
  tail -n "$LOG_MAX_LINES" "$LOG" > "$tmp_log" && mv "$tmp_log" "$LOG"
fi

fmt_secs() {
  local s="$1"
  printf "%02d:%02d:%02d" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

log() {
  local msg="$1"
  local ts
  ts="$(date '+%F %T')"
  echo "[$ts] $msg" | tee -a "$LOG"
  logger -t srt-rename "$msg" 2>/dev/null || true
}

START_TS="$(date +%s)"
CURRENT_ROOT="(none)"
LAST_FILE="(none)"
LAST_BEAT_TS="$START_TS"

found=0 renamed=0 skipped=0 errors=0 deleted=0 differ=0

beat() {
  local now elapsed
  now="$(date +%s)"
  elapsed=$((now - START_TS))
  log "HEARTBEAT | elapsed=$(fmt_secs "$elapsed") | root=\"$CURRENT_ROOT\" | found=$found renamed=$renamed deleted=$deleted differ=$differ skipped=$skipped errors=$errors | last=\"$LAST_FILE\""
  LAST_BEAT_TS="$now"
}

# releases dentries and inodes only, no data touched
drop_caches() {
  sync
  echo 2 > /proc/sys/vm/drop_caches 2>/dev/null || true
}

# target exists: drop the source only when the two are byte identical
handle_dedupe() {
  local file="$1" new_file="$2"

  if ! cmp -s "$file" "$new_file"; then
    differ=$(( differ + 1 ))
    log "DIFFER (kept both, manual call needed): $file"
    return
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    deleted=$(( deleted + 1 ))
    log "[DRY-RUN] Would delete duplicate: $file"
    return
  fi

  if rm -f -- "$file"; then
    deleted=$(( deleted + 1 ))
    log "Deleted duplicate: $file"
  else
    errors=$(( errors + 1 ))
    log "ERROR deleting: $file"
  fi
}

process_one() {
  local file="$1"
  found=$(( found + 1 ))
  LAST_FILE="$file"

  local tail8="${file: -8}"
  if [[ "${tail8,,}" != ".gre.srt" ]]; then
    skipped=$(( skipped + 1 ))
    log "SKIP (no suffix match): $file"
    return
  fi

  local new_file="${file:0:${#file}-8}.ell.srt"

  if [[ "$new_file" == "$file" ]]; then
    skipped=$(( skipped + 1 ))
    log "SKIP (already target name): $file"
    return
  fi

  if [[ -e "$new_file" ]]; then
    if [[ $DEDUPE -eq 1 ]]; then
      handle_dedupe "$file" "$new_file"
      return
    fi
    if [[ $FORCE -eq 0 ]]; then
      skipped=$(( skipped + 1 ))
      log "SKIP (target exists): $file -> $new_file"
      return
    fi
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    renamed=$(( renamed + 1 ))
    log "[DRY-RUN] Would rename: $file -> $new_file"
    return
  fi

  if mv -- "$file" "$new_file"; then
    renamed=$(( renamed + 1 ))
    log "Renamed: $file -> $new_file"
  else
    errors=$(( errors + 1 ))
    log "ERROR renaming: $file"
  fi
}

scan_dir() {
  local dir="$1"
  CURRENT_ROOT="$dir"
  log "Scanning: $dir"

  local now
  if [[ $FULL -eq 0 && -f "$STATE" ]]; then
    while IFS= read -r -d '' file; do
      now="$(date +%s)"
      (( now - LAST_BEAT_TS >= HEARTBEAT_SECS )) && beat
      process_one "$file"
    done < <(find "$dir" \( -type d -name ".Recycle.Bin" -prune \) -o \
      \( -type f -iname "*.gre.srt" -newer "$STATE" -print0 \))
  else
    while IFS= read -r -d '' file; do
      now="$(date +%s)"
      (( now - LAST_BEAT_TS >= HEARTBEAT_SECS )) && beat
      process_one "$file"
    done < <(find "$dir" \( -type d -name ".Recycle.Bin" -prune \) -o \
      \( -type f -iname "*.gre.srt" -print0 \))
  fi
}

# collect candidate volumes
VOLS=()
shopt -s nullglob
for v in "$MNT"/*; do
  [[ -d "$v" ]] || continue
  name="$(basename "$v")"
  [[ " $VOL_SKIP " == *" $name "* ]] && continue
  for sub in "${SUBROOTS[@]}"; do
    [[ -d "$v/$sub" ]] && { VOLS+=("$v"); break; }
  done
done
shopt -u nullglob

log "---- RUN START ----"
log "Mode: FULL=$FULL | DRY_RUN=$DRY_RUN | FORCE=$FORCE | DEDUPE=$DEDUPE | DropCaches=$DROP_CACHES | Heartbeat=${HEARTBEAT_SECS}s"
[[ -n "${DEPRECATED_ARG:-}" ]] && log "NOTE: $DEPRECATED_ARG is deprecated and ignored (per-volume scan replaces the wake pass)"

if [[ ${#VOLS[@]} -eq 0 ]]; then
  log "ABORT: no volume under $MNT contains any of: ${SUBROOTS[*]}"
  exit 1
fi

log "Volumes with content: ${#VOLS[@]}"
for v in "${VOLS[@]}"; do
  log "  -> $v"
done

if [[ $FULL -eq 0 ]]; then
  if [[ -f "$STATE" ]]; then
    log "Incremental since: $(date -r "$STATE")"
  else
    log "Incremental since: (none) -> first run will behave like full for matches"
  fi
else
  log "FULL scan mode"
fi

beat

for vol in "${VOLS[@]}"; do
  vol_found_before=$found
  vol_renamed_before=$renamed
  vol_deleted_before=$deleted

  for sub in "${SUBROOTS[@]}"; do
    [[ -d "$vol/$sub" ]] || continue
    scan_dir "$vol/$sub"
  done

  log "Finished volume: $vol | found=$(( found - vol_found_before )) renamed=$(( renamed - vol_renamed_before )) deleted=$(( deleted - vol_deleted_before ))"

  # keep dentry cache from accumulating across the whole run
  [[ $DROP_CACHES -eq 1 ]] && drop_caches
done

END_TS="$(date +%s)"
TOTAL_SECS=$((END_TS - START_TS))

log "=== DONE ==="
log "TOTAL: Found=$found | Renamed=$renamed | Deleted=$deleted | Differ=$differ | Skipped=$skipped | Errors=$errors | Duration=$(fmt_secs "$TOTAL_SECS")"

# broken roots are already caught by the VOLS=0 abort above, so found=0 here just means clean
if [[ $DEDUPE -eq 1 ]]; then
  log "State NOT updated (dedupe mode)"
elif [[ $DRY_RUN -eq 1 ]]; then
  log "State NOT updated (dry-run)"
elif [[ $errors -ne 0 ]]; then
  log "State NOT updated ($errors errors present)"
else
  [[ $found -eq 0 ]] && log "Nothing to do, library already clean."
  touch "$STATE"
  touch "$SUCCESS_MARK"
  log "State updated: $STATE"
  log "Success marker updated: $SUCCESS_MARK"
fi

exit 0
