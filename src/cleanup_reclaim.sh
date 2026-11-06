#!/data/data/com.termux/files/usr/bin/bash
# cleanup_reclaim.sh — Termux Home Directory Space Reclaimer (fixed)
# Usage: bash ~/cleanup_reclaim.sh [--dry-run|--yes]
set -euo pipefail

DRY_RUN=false; ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=true ;;
    --yes|-y)     ASSUME_YES=true ;;
    --help|-h) echo "Usage: $0 [--dry-run] [--yes]"; exit 0 ;;
    *) echo "Unknown flag: $arg"; exit 1 ;;
  esac
done

if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BOLD=$'\033[1m';   DIM=$'\033[2m';      RESET=$'\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BOLD=''; DIM=''; RESET=''
fi

human_size() {
  local b=$1
  if   (( b >= 1073741824 )); then awk -v x="$b" 'BEGIN{printf "%.2f GB", x/1073741824}'
  elif (( b >= 1048576    )); then awk -v x="$b" 'BEGIN{printf "%.1f MB", x/1048576}'
  elif (( b >= 1024       )); then awk -v x="$b" 'BEGIN{printf "%.1f KB", x/1024}'
  else echo "${b} B"; fi
}

size_of() {
  local f=$1 s=""
  if [[ -f "$f" ]]; then
    s=$(stat -c %s "$f" 2>/dev/null) || s=$(wc -c < "$f" 2>/dev/null) || s=0
  elif [[ -d "$f" ]]; then
    s=$(du -sb "$f" 2>/dev/null | awk '{print $1}')
    [[ -z "$s" ]] && s=$(( $(du -sk "$f" 2>/dev/null | awk '{print $1}') * 1024 ))
  fi
  echo "${s:-0}"
}

expand_paths() {
  local p="$1"; p="${p/#\~/$HOME}"
  if [[ "$p" != *"*"* ]]; then
    [[ -e "$p" ]] && printf '%s\0' "$p"
  else
    find "${p%/*}" -maxdepth 1 -name "${p##*/}" -print0 2>/dev/null
  fi
  return 0
}

get_size_bytes() {
  local total=0 f
  while IFS= read -r -d '' f; do
    total=$(( total + $(size_of "$f") ))
  done < <(expand_paths "$1")
  echo "$total"
}

# Return codes: 0=confirmed, 1=declined, 2=dry-run
confirm() {
  printf "\n  %s%-55s %10s%s\n" "$BOLD" "$1" "$3" "$RESET"
  if $DRY_RUN; then printf "  %s[DRY RUN] Would remove%s\n" "$YELLOW" "$RESET"; return 2; fi
  if $ASSUME_YES; then return 0; fi
  local ans; read -rp "  Remove? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}

do_remove() {
  local p="$1"; p="${p/#\~/$HOME}"
  $DRY_RUN && return 0
  if [[ "$p" == "$HOME/backups" ]]; then
    local bundles i
    mapfile -t bundles < <(ls -t "$HOME"/backups/keystone_*.bundle 2>/dev/null || true)
    for ((i=1; i<${#bundles[@]}; i++)); do rm -f "${bundles[$i]}"; done
    return 0
  fi
  while IFS= read -r -d '' f; do rm -rf "$f"; done < <(expand_paths "$1")
  return 0
}

echo ""
echo "${BOLD}=============================================="
echo "  Termux Home Cleanup — Space Reclaimer"
echo "==============================================${RESET}"
if $DRY_RUN; then echo "${YELLOW}  ** DRY RUN MODE — no files will be deleted **${RESET}"; fi
df -h /data/user/0 2>/dev/null | tail -1 | awk '{printf "  Disk: Total %s | Used %s (%s) | Free %s\n",$2,$3,$5,$4}' || true

CANDIDATES=(
  "test-backup.tar.gz|~/test-backup.tar.gz"
  "Goldenfoss/Active_Projects (dup)|~/Goldenfoss/Active_Projects"
  "ez_termux_backup/Active_Projects (dup)|~/ez_termux_backup_flashdrive/Active_Projects"
  "Chrombook/Active_Projects (dup)|~/Chrombook_crostini_repair_guide/Active_Projects"
  "tech-ref-portal/node_modules|~/tech-ref-portal/node_modules"
  "capyreader/node_modules|~/capyreader/node_modules"
  "tech-ref-portal.stale|~/tech-ref-portal.stale"
  "Keystone_Health_downloadable_files|~/Keystone_Health_downloadable_files"
  "duck-dev/keystone-sync (mirror)|~/duck-dev/keystone-sync"
  "keystone_extract|~/keystone_extract"
  "old keystone bundles (keep newest)|~/backups"
  "pixel-terminal .tgz (3x)|~/pixel-terminal-master.*.tgz"
  "vid2gif-repo.tar.gz|~/vid2gif-repo.tar.gz"
  "animated-umbrella.tar.gz|~/animated-umbrella.tar.gz"
  "ctx_report_*.txt (old)|~/ctx_report_*.txt"
  "deployment_*.log (old)|~/deployment_*.log"
  "test_results_*.xml (old)|~/test_results_*.xml"
  "keystone_fix* (scripts+logs)|~/keystone_fix*"
  "keystone_triage* (script+log)|~/keystone_triage*"
  "keystone_verify* (scripts+logs)|~/keystone_verify*"
  "tmu_probe* (script+log)|~/tmu_probe*"
  "env_audit_*.txt (old)|~/env_audit_*.txt"
  "session_context.txt|~/session_context.txt"
  "report.json (stale)|~/report.json"
  "_quarantine|~/_quarantine"
)

total_candidate=0
LABELS=(); PATHS=(); SIZES=()
printf "\n  %-55s %12s\n" "PATH" "SIZE"
for entry in "${CANDIDATES[@]}"; do
  label="${entry%%|*}"; path="${entry##*|}"
  size=$(get_size_bytes "$path") || size=0
  printf "  %-55s %12s\n" "$label" "$(human_size "$size")"
  total_candidate=$(( total_candidate + size ))
  LABELS+=("$label"); PATHS+=("$path"); SIZES+=("$size")
done
printf "\n  %sTotal reclaimable: %s%s\n\n" "$BOLD" "$(human_size "$total_candidate")" "$RESET"

# --- Phase 2: Active_Projects dedup ---
echo "${BOLD}--- DEDUP: Active_Projects triple-copy ---${RESET}"
AP_A="$HOME/Goldenfoss/Active_Projects"
AP_B="$HOME/ez_termux_backup_flashdrive/Active_Projects"
AP_C="$HOME/Chrombook_crostini_repair_guide/Active_Projects"
if $DRY_RUN; then
  echo "  ${YELLOW}[DRY RUN] Would ask canonical (A/B/C, default B), remove two copies.${RESET}"
else
  read -rp "  Canonical? [A=Goldenfoss/B=flashdrive/C=Chrombook] (default B) " c; c="${c:-B}"
  case "$c" in
    A) do_remove "$AP_B"; do_remove "$AP_C" ;;
    B) do_remove "$AP_A"; do_remove "$AP_C" ;;
    C) do_remove "$AP_A"; do_remove "$AP_B" ;;
    *) echo "  Skipping dedup." ;;
  esac
fi

# --- Phase 3: Per-item removal ---
echo ""; echo "${BOLD}--- REMOVAL: confirming each target ---${RESET}"
reclaimed=0; removed=0; skipped=0
for i in "${!LABELS[@]}"; do
  case "${PATHS[$i]}" in *Active_Projects*) continue ;; esac
  if (( SIZES[i] == 0 )); then skipped=$(( skipped + 1 )); continue; fi
  set +e
  confirm "${LABELS[$i]}" "" "$(human_size "${SIZES[$i]}")"
  rc=$?
  set -e
  if (( rc == 2 )); then
    printf "  ${DIM}would remove: %s${RESET}\n" "${LABELS[$i]}"
  elif (( rc == 0 )); then
    do_remove "${PATHS[$i]}"
    reclaimed=$(( reclaimed + SIZES[i] )); removed=$(( removed + 1 ))
    printf "  ${GREEN}OK removed: %s${RESET}\n" "${LABELS[$i]}"
  else
    skipped=$(( skipped + 1 ))
    printf "  ${YELLOW}skipped: %s${RESET}\n" "${LABELS[$i]}"
  fi
done

# --- Phase 4: Summary ---
echo ""; echo "${BOLD}================ SUMMARY ================${RESET}"
echo "  Removed: $removed   Skipped: $skipped   Reclaimed: $(human_size "$reclaimed")"
df -h /data/user/0 2>/dev/null | tail -1 | awk '{printf "  Disk now: Used %s (%s) | Free %s\n",$3,$5,$4}' || true
usage=$(df /data/user/0 2>/dev/null | awk 'NR==2{gsub(/%/,"");print $5}')
if [[ -n "$usage" ]] && (( usage >= 85 )); then
  echo "  ${RED}WARNING: still at ${usage}%% — largest dirs:${RESET}"
  du -sh "$HOME"/*/ 2>/dev/null | sort -rh | head -10 | sed 's/^/    /'
fi
if $DRY_RUN; then echo "  ${YELLOW}** DRY RUN — nothing changed. Re-run without --dry-run. **${RESET}"; fi
echo ""; echo "  Done."
