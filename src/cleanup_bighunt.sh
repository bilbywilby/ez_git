#!/data/data/com.termux/files/usr/bin/bash
# cleanup_bighunt.sh — drill into heavy dirs; pick items by number
# Usage: bash ~/cleanup_bighunt.sh [--dry-run] [--yes]
set -u
DRY=0; YES=0
for a in "$@"; do
  case $a in -n|--dry-run) DRY=1 ;; -y|--yes) YES=1 ;; esac
done
hs() { local b=$1
  if   (( b >= 1073741824 )); then awk -v x="$b" 'BEGIN{printf "%.2f GB",x/1073741824}'
  elif (( b >= 1048576 )); then awk -v x="$b" 'BEGIN{printf "%.1f MB",x/1048576}'
  elif (( b >= 1024 )); then awk -v x="$b" 'BEGIN{printf "%.1f KB",x/1024}'
  else echo "${b} B"; fi; }
DIRS=("$HOME/shh" "$HOME/downloads" "$HOME/.cargo" "$HOME/.git_archive"
      "$HOME/Active_Projects" "$HOME/Chrombook_crostini_repair_guide"
      "$HOME/Goldenfoss" "$HOME/ez_termux_backup_flashdrive" "$HOME/backups")
TOT=0
for d in "${DIRS[@]}"; do
  [[ -d $d ]] || continue
  KB=$(du -sk "$d" 2>/dev/null | awk '{print $1}')
  echo; echo "== ${d#$HOME/} ==  ($(hs $((KB*1024))))"
  n=0; L=(); S=()
  while IFS=$'\t' read -r k p; do
    n=$((n+1)); L+=("$p"); S+=($((k*1024)))
    printf "  %2d) %-46s %s\n" "$n" "${p#$d/}" "$(hs $((k*1024)))"
  done < <(du -sk "$d"/* "$d"/.[!.]* 2>/dev/null | sort -rn)
  (( n == 0 )) && continue
  read -rp "  Remove which? (numbers like 1 3 | a=all | Enter=skip) " sel
  [[ -z $sel ]] && continue
  picks=()
  if [[ $sel == a ]]; then for ((i=1;i<=n;i++)); do picks+=("$i"); done
  else
    for x in $sel; do
      [[ $x =~ ^[0-9]+$ ]] && (( x>=1 && x<=n )) && picks+=("$x")
    done
  fi
  (( ${#picks[@]} == 0 )) && continue
  batch=0
  for i in "${picks[@]}"; do batch=$((batch+S[i-1])); done
  echo "  selected ${#picks[@]} item(s): $(hs $batch)"
  if (( DRY )); then echo "  [DRY RUN] would remove"; TOT=$((TOT+batch)); continue; fi
  if (( ! YES )); then
    read -rp "  Confirm removal? [y/N] " c
    [[ $c =~ ^[Yy]$ ]] || { echo "  skipped."; continue; }
  fi
  for i in "${picks[@]}"; do
    rm -rf -- "${L[i-1]}"; echo "  removed: ${L[i-1]#$HOME/}"
  done
  TOT=$((TOT+batch))
done
echo; echo "Total ${DRY:+would-have-}reclaimed: $(hs $TOT)"
