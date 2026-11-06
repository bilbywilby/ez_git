mkdir -p ~/projects && cat > ~/projects/git_superuser_workflow.sh << 'GSW1'
#!/usr/bin/env bash
# git_superuser_workflow - Hardened for Termux/puppygit
# Version: 2026.11.06 (fixed: set -e exits, dry-run side effects, mobile GC config)
# Usage: ./git_superuser_workflow.sh <command> [--dry-run] [--json] [--workdir DIR] [--check]

set -euo pipefail
IFS=$'\n\t'

SCRIPT_NAME="${0##*/}"
VERSION="2026.11.06"
DRY_RUN=0
JSON_OUT=0
WORKDIR="$(pwd)"
SELFTEST=0
WF_TMPDIR=""

LOG_DIR="${HOME:-/tmp}/.local/log/git_workflow"
SNAPSHOT_DIR="${HOME:-/tmp}/.local/snapshots"
SNAPSHOT_RETAIN=5
SNAPSHOT_MAX_BYTES=$((200*1024*1024))
LARGE_FILE_LIMIT_BYTES=$((10*1024*1024))

if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERROR: Requires bash." >&2
  exit 2
fi

_cmd() { command -v "$1" 2>/dev/null || printf "%s\n" ""; }
TAR_CMD=$(_cmd tar || true)
DATE_CMD=$(_cmd date || true)
SHA256SUM_CMD=$(_cmd sha256sum || _cmd shasum || true)
AWK_CMD=$(_cmd awk || true)
DU_CMD=$(_cmd du || true)

mktemp_dir() {
  if [ -n "${WF_TMPDIR:-}" ] && [ -d "$WF_TMPDIR" ]; then
    printf '%s' "$WF_TMPDIR"; return 0
  fi
  local try
  for try in "$(pwd)" "/data/data/com.termux/files/usr/tmp" "/tmp" "/var/tmp"; do
    if [ -d "$try" ] && [ -w "$try" ]; then
      WF_TMPDIR=$(mktemp -d "${try}/git_workflow.XXXXXX" 2>/dev/null || true)
      [ -n "${WF_TMPDIR:-}" ] && { printf '%s' "$WF_TMPDIR"; return 0; }
    fi
  done
  echo "ERROR: unable to create temporary directory" >&2
  return 1
}

cleanup() {
  if [ -n "${WF_TMPDIR:-}" ] && [ -d "${WF_TMPDIR}" ]; then
    rm -rf "${WF_TMPDIR}"
  fi
}
trap cleanup EXIT

# NOTE: directory creation moved AFTER flag parsing so --dry-run is side-effect-free
mkdir_p() {
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    echo "[DRY-RUN] mkdir -p \"$1\""
  else
    mkdir -p "$1"
  fi
}

_log() {
  local level="$1" message="$2"
  local timestamp
  timestamp=$("${DATE_CMD:-date}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
  case "$level" in
    error) printf "[%s] [ERROR] %s\n" "$timestamp" "$message" >&2 ;;
    warn)  printf "[%s] [WARN]  %s\n" "$timestamp" "$message" >&2 ;;
    info)  printf "[%s] [INFO]  %s\n" "$timestamp" "$message" ;;
    *)     printf "[%s] [%s]  %s\n" "$timestamp" "${level^^}" "$message" ;;
  esac
  if [ "${DRY_RUN:-0}" -eq 0 ] && [ -d "${LOG_DIR}" ]; then
    printf "[%s] [%s] %s\n" "$timestamp" "${level^^}" "$message" \
      >> "${LOG_DIR}/${SCRIPT_NAME}.log" 2>/dev/null || true
  fi
}

run_or_dry() {
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    _log info "[DRY-RUN] $*"
    return 0
  fi
  bash -c "$*" || return $?
}

numfmt_or_human() {
  local size="$1"
  if command -v numfmt >/dev/null 2>&1; then
    numfmt --to=iec-i --suffix=B --padding=7 "$size" 2>/dev/null || printf "%sB" "$size"
  else
    "${AWK_CMD:-awk}" -v s="$size" 'function human(x){
      split("B KB MB GB TB PB",u); i=1;
      while(x>1024 && i<6){x/=1024; i++}
      return sprintf("%.1f %s", x, u[i]);
    }{print human(s)}'
  fi
}

safe_stat_size() {
  local file="$1"
  if [ -z "$file" ] || [ ! -e "$file" ]; then echo 0; return; fi
  stat -c "%s" "$file" 2>/dev/null || stat -f "%z" "$file" 2>/dev/null || wc -c <"$file" 2>/dev/null || echo 0
}

prune_snapshots() {
  local prefix="${SCRIPT_NAME%%.*}_"
  local files
  mapfile -t files < <(find "${SNAPSHOT_DIR}" -maxdepth 1 -type f -name "${prefix}*.tar.gz" -printf '%T@ %p\n' 2>/dev/null | sort -n -r | awk '{print $2}')
  local f
  for f in "${files[@]:${SNAPSHOT_RETAIN}}"; do
    [ -z "$f" ] && continue
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
      _log info "[DRY-RUN] rm -f \"$f\""
    else
      rm -f "$f" || _log warn "Failed to remove old snapshot: $f"
    fi
  done
  return 0
}

check_repo_size() {
  if command -v du >/dev/null 2>&1; then
    local size_mb
    size_mb=$("${DU_CMD}" -sm . 2>/dev/null | cut -f1 || echo 0)
    if [ "$size_mb" -gt 500 ]; then
      _log warn "Repository size ${size_mb} MB may be slow on Termux."
    fi
  fi
  return 0
}

primary_branch() {
  local pb
  pb=$(git for-each-ref --format='%(refname:short)' refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||' || true)
  if [ -n "$pb" ]; then printf '%s' "$pb"; return 0; fi
  local candidate
  for candidate in main master trunk; do
    if git show-ref --verify --quiet "refs/heads/$candidate"; then printf '%s' "$candidate"; return 0; fi
  done
  printf 'main'
}

require_cmds() {
  local miss=0 cmd
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf 'MISSING: %s\n' "$cmd" >&2
      miss=1
    fi
  done
  return "$miss"
}

# Shared: print JSON report if --json was passed (FIX: no bare && under set -e)
emit_json() {
  if [ "${JSON_OUT:-0}" -eq 1 ]; then
    cat "$1"
  fi
  return 0
}

dependency_master() {
  _log info "Running dependency_master for $(pwd)."
  local DEPENDENCY_TRACKERS=( "package.json:npm" "requirements.txt:pip" "Gemfile:bundle" "pom.xml:mvn" "go.mod:go" "Cargo.toml:cargo" )
  local reports_human="./dependency_master_report.txt"
  local reports_json="./dependency_master_report.json"
  : > "$reports_human"
  printf '{ "updates": [\n' > "$reports_json"
  local first_entry=1

  local tracker FILE TOOL
  for tracker in "${DEPENDENCY_TRACKERS[@]}"; do
    FILE=${tracker%%:*}
    TOOL=${tracker##*:}
    if [ ! -f "$FILE" ]; then continue; fi

    printf '--- Detected %s (tool: %s) ---\n' "$FILE" "$TOOL" | tee -a "$reports_human"

    local entry_status="ok" entry_msg=""
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
      entry_status="dry-run"
      entry_msg="Would run $TOOL for $FILE"
      printf '%s\n' "[DRY-RUN] $entry_msg" | tee -a "$reports_human"
    else
      case "$TOOL" in
        npm)
          if command -v npm >/dev/null 2>&1; then
            if ! run_or_dry "npm update --no-audit --no-fund --no-optional"; then entry_status="error"; entry_msg="npm update failed"; fi
            run_or_dry "npm audit fix --silent || true"
          else entry_status="missing-tool"; entry_msg="npm not installed"; fi
          ;;
        pip)
          local VENV_ACTIVATED=0
          if [ -d "venv" ] && [ -f "venv/bin/activate" ]; then
            # shellcheck disable=SC1091
            . venv/bin/activate && VENV_ACTIVATED=1 || VENV_ACTIVATED=0
          fi
          if command -v pip >/dev/null 2>&1; then
            if ! run_or_dry "pip install --upgrade -r \"$FILE\""; then entry_status="error"; entry_msg="pip install failed"; fi
            command -v safety >/dev/null 2>&1 && run_or_dry "safety check" || true
          else entry_status="missing-tool"; entry_msg="pip not installed"; fi
          if [ "$VENV_ACTIVATED" -eq 1 ]; then deactivate || true; fi
          ;;
        bundle)
          if command -v bundle >/dev/null 2>&1; then
            if ! run_or_dry "bundle update"; then entry_status="error"; entry_msg="bundle update failed"; fi
            command -v bundler-audit >/dev/null 2>&1 && run_or_dry "bundler-audit check" || true
          else entry_status="missing-tool"; entry_msg="bundle not installed"; fi
          ;;
        mvn)
          if command -v mvn >/dev/null 2>&1; then
            if ! run_or_dry "mvn versions:update-properties -DgenerateBackupPoms=false"; then entry_status="error"; entry_msg="mvn update failed"; fi
          else entry_status="missing-tool"; entry_msg="mvn not installed"; fi
          ;;
        go)
          if command -v go >/dev/null 2>&1; then
            if ! run_or_dry "go get -u ./..."; then entry_status="error"; entry_msg="go get failed"; fi
            run_or_dry "go mod tidy" || true
          else entry_status="missing-tool"; entry_msg="go not installed"; fi
          ;;
        cargo)
          if command -v cargo >/dev/null 2>&1; then
            if ! run_or_dry "cargo update"; then entry_status="error"; entry_msg="cargo update failed"; fi
            command -v cargo-audit >/dev/null 2>&1 && run_or_dry "cargo audit" || true
          else entry_status="missing-tool"; entry_msg="cargo not installed"; fi
          ;;
        *) entry_status="unknown"; entry_msg="unknown tool" ;;
      esac
    fi

    local json_entry
    json_entry=$(printf '{"file":"%s","tool":"%s","status":"%s","message":"%s"}' \
                 "$(printf '%s' "$FILE" | sed 's/"/\\"/g')" \
                 "$(printf '%s' "$TOOL" | sed 's/"/\\"/g')" \
                 "$(printf '%s' "$entry_status" | sed 's/"/\\"/g')" \
                 "$(printf '%s' "$entry_msg" | sed 's/"/\\"/g')")
    if [ "$first_entry" -eq 1 ]; then
      printf '  %s\n' "$json_entry" >> "$reports_json"; first_entry=0
    else
      printf ' , %s\n' "$json_entry" >> "$reports_json"
    fi
    printf 'Finished processing %s\n' "$FILE" | tee -a "$reports_human"
  done

  printf '] }\n' >> "$reports_json"
  _log info "Dependency master complete. Reports: $reports_human, $reports_json"
  emit_json "$reports_json"
}
GSW1
echo "Part 1 written."
