# git_superuser_workflow - Hardened for Termux/puppygit
# Version: 2025.11.14
# Usage: ./git_superuser_workflow.sh <command> [--dry-run] [--json] [--workdir DIR] [--check]

set -euo pipefail
IFS=$'\n\t'

# ----------------------------------------------------------------------
# Globals & Setup
# ----------------------------------------------------------------------
SCRIPT_NAME="${0##*/}"
VERSION="2025.11.14"
DRY_RUN=0
JSON_OUT=0
WORKDIR="$(pwd)"
SELFTEST=0
WF_TMPDIR=""

LOG_DIR="${HOME:-/tmp}/.local/log/git_workflow"
SNAPSHOT_DIR="${HOME:-/tmp}/.local/snapshots"
SNAPSHOT_RETAIN=5                    # keep last N snapshots
SNAPSHOT_MAX_BYTES=$((200*1024*1024)) # 200 MiB warning threshold
LARGE_FILE_LIMIT_BYTES=$((10*1024*1024)) # 10 MiB pre-commit limit
TOOL_TOLERANCE=1                     # seconds tolerance for missing tools

if [ -z "${BASH_VERSION:-}" ]; then
  echo "ERROR: Requires bash." >&2
  exit 2
fi

# Portable command resolution
_cmd() { command -v "$1" 2>/dev/null || printf "%s\n" ""; }
TAR_CMD=$(_cmd tar || true)
DATE_CMD=$(_cmd date || true)
STAT_CMD=$(_cmd stat || true)
SHA256SUM_CMD=$(_cmd sha256sum || _cmd shasum || true)
AWK_CMD=$(_cmd awk || true)
DU_CMD=$(_cmd du || true)
XARGS_CMD=$(_cmd xargs || true)

# Safer portable mktemp_dir
mktemp_dir() {
  if [ -n "${WF_TMPDIR:-}" ] && [ -d "$WF_TMPDIR" ]; then
    printf '%s' "$WF_TMPDIR"
    return 0
  fi

  local try
  for try in "$(pwd)" "/data/data/com.termux/files/usr/tmp" "/tmp" "/var/tmp"; do
    if [ -d "$try" ] && [ -w "$try" ]; then
      WF_TMPDIR=$(mktemp -d "${try}/git_workflow.XXXXXX" 2>/dev/null || true)
      [ -n "${WF_TMPDIR:-}" ] && { printf '%s' "$WF_TMPDIR"; return 0; }
    fi
  done

  WF_TMPDIR=$(mktemp -d 2>/dev/null || true)
  if [ -n "${WF_TMPDIR:-}" ]; then
    printf '%s' "$WF_TMPDIR"
    return 0
  fi

  echo "ERROR: unable to create temporary directory" >&2
  return 1
}

cleanup() {
  if [ -n "${WF_TMPDIR:-}" ] && [ -d "${WF_TMPDIR}" ]; then
    rm -rf "${WF_TMPDIR}"
  fi
}
trap cleanup EXIT

# Ensure required directories exist
mkdir_p() {
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    echo "[DRY-RUN] mkdir -p \"$1\""
  else
    mkdir -p "$1"
  fi
}
mkdir_p "${LOG_DIR}"
mkdir_p "${SNAPSHOT_DIR}"

# ----------------------------------------------------------------------
# Logging & Utility Helpers
# ----------------------------------------------------------------------
_log() {
  local level="$1" message="$2"
  local timestamp
  timestamp=$("${DATE_CMD:-date}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
  local log_file="${LOG_DIR}/${SCRIPT_NAME}.log"
  case "$level" in
    error) printf "[%s] [ERROR] %s\n" "$timestamp" "$message" >&2 ;;
    warn)  printf "[%s] [WARN]  %s\n" "$timestamp" "$message" >&2 ;;
    info)  printf "[%s] [INFO]  %s\n" "$timestamp" "$message" ;;
    *)     printf "[%s] [%s]  %s\n" "$timestamp" "${level^^}" "$message" ;;
  esac
  if [ "${DRY_RUN:-0}" -eq 0 ]; then
    printf "[%s] [%s] %s\n" "$timestamp" "${level^^}" "$message" >> "$log_file" 2>/dev/null || true
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
  if command -v stat >/dev/null 2>&1; then
    if stat -c "%s" "$file" 2>/dev/null; then
      stat -c "%s" "$file" 2>/dev/null || echo 0
    else
      stat -f "%z" "$file" 2>/dev/null || echo 0
    fi
  else
    wc -c <"$file" 2>/dev/null || echo 0
  fi
}

prune_snapshots() {
  local prefix="${SCRIPT_NAME%%.*}_"
  local files
  mapfile -t files < <(find "${SNAPSHOT_DIR}" -maxdepth 1 -type f -name "${prefix}*.tar.gz" -printf '%T@ %p\n' 2>/dev/null |
    sort -n -r | awk '{print $2}')
  for f in "${files[@]:${SNAPSHOT_RETAIN}}"; do
    [ -z "$f" ] && continue
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
      _log info "[DRY-RUN] rm -f \"$f\""
    else
      rm -f "$f" || _log warn "Failed to remove old snapshot: $f"
    fi
  done
}

check_repo_size() {
  if command -v du >/dev/null 2>&1; then
    local size_mb
    size_mb=$(( $(${DU_CMD} -sm . 2>/dev/null | cut -f1 || echo 0) ))
    if [ "$size_mb" -gt 500 ]; then
      _log warn "Repository size ${size_mb} MB may be slow on Termux."
    fi
  fi
}

primary_branch() {
  local pb
  pb=$(git for-each-ref --format='%(refname:short)' refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||' || true)
  if [ -n "$pb" ]; then printf '%s' "$pb"; return 0; fi
  for candidate in main master trunk; do
    if git show-ref --verify --quiet "refs/heads/$candidate"; then printf '%s' "$candidate"; return 0; fi
  done
  printf 'main'
}

require_cmds() {
  local miss=0
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      printf 'MISSING: %s\n' "$cmd" >&2
      miss=1
    fi
  done
  return $miss
}

# ----------------------------------------------------------------------
# Core Functions
# ----------------------------------------------------------------------
dependency_master() {
  _log info "Running dependency_master for $(pwd)."
  local DEPENDENCY_TRACKERS=( "package.json:npm" "requirements.txt:pip" "Gemfile:bundle" "pom.xml:mvn" "go.mod:go" "Cargo.toml:cargo" )
  local reports_human="./dependency_master_report.txt"
  local reports_json="./dependency_master_report.json"
  : > "$reports_human"
  : > "$reports_json"

  printf '{ "updates": [\n' > "$reports_json"
  local first_entry=1

  for tracker in "${DEPENDENCY_TRACKERS[@]}"; do
    local FILE=${tracker%%:*}
    local TOOL=${tracker##*:}
    if [ ! -f "$FILE" ]; then
      continue
    fi

    printf '--- Detected %s (tool: %s) ---\n' "$FILE" "$TOOL" | tee -a "$reports_human"

    local entry_status="ok"
    local entry_msg=""
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
          [ "$VENV_ACTIVATED" -eq 1 ] && deactivate || true
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
        *)
          entry_status="unknown"; entry_msg="unknown tool"
          ;;
      esac
    fi

    local json_entry
    json_entry=$(printf '{"file":"%s","tool":"%s","status":"%s","message":"%s"}' \
                 "$(printf '%s' "$FILE" | sed 's/"/\\"/g')" \
                 "$(printf '%s' "$TOOL" | sed 's/"/\\"/g')" \
                 "$(printf '%s' "$entry_status" | sed 's/"/\\"/g')" \
                 "$(printf '%s' "$entry_msg" | sed 's/"/\\"/g')")

    if [ "$first_entry" -eq 1 ]; then
      printf '  %s\n' "$json_entry" >> "$reports_json"
      first_entry=0
    else
      printf ' , %s\n' "$json_entry" >> "$reports_json"
    fi

    printf 'Finished processing %s\n' "$FILE" | tee -a "$reports_human"
  done

  printf '] }\n' >> "$reports_json"
  _log info "Dependency master complete. Reports: $reports_human, $reports_json"
  [ "${JSON_OUT:-0}" -eq 1 ] && cat "$reports_json"
}

git_security_audit() {
  if ! command -v jq >/dev/null 2>&1; then
    _log error "'jq' is required for security audit."
    exit 1
  fi
  _log info "Running Git Security Audit..."
  local human="./git_security_audit_report.txt"
  local json="./git_security_audit_report.json"
  : > "$human"
  : > "$json"

  local PB
  PB=$(primary_branch)
  local audit_time
  audit_time=$(date '+%F %T' 2>/dev/null || date '+%F %T')

  local secret_status="skipped"
  local secret_output_json='[]'
  local lfs_status="no"
  local large_files_json='[]'
  local divergence_json='[]'

  local lf_tmp div_tmp
  lf_tmp="$(mktemp_dir)/large_files.$$.$(date +%s).json"
  div_tmp="$(mktemp_dir)/divergence.$$.$(date +%s).json"
  : > "$lf_tmp"
  : > "$div_tmp"

  {
    printf '=== Git Security Audit (%s) ===\n' "$audit_time"
    printf 'Primary branch: %s\n\n' "$PB"

    printf '1) Secret-pattern scan (recent 200 commits):\n'
    if command -v gitleaks >/dev/null 2>&1; then
      if [ "${DRY_RUN:-0}" -eq 1 ]; then
        printf '[DRY-RUN] gitleaks detect --report-format json --report-path ./gitleaks.json --max-count=200\n'
        secret_status="dry-run"
      else
        local tmpf
        tmpf="$(mktemp_dir)/gitleaks.$(date +%s%N).json"
        gitleaks detect --report-format json --report-path "$tmpf" --log-opts "--max-count=200" >/dev/null 2>&1 || true
        if [ -s "$tmpf" ]; then
          secret_output_json=$(jq -c '.' "$tmpf" 2>/dev/null || printf '%s' '[]')
          local hits
          hits=$(printf '%s' "$secret_output_json" | jq 'length' 2>/dev/null || echo 0)
          if [ "$hits" -gt 0 ]; then
             secret_status="leaks-found"
             printf 'Leaks found (showing first 5):\n'
             jq -r '.[] | "\(.Rule.ID) in \(.File): \(.Commit)"' "$tmpf" 2>/dev/null | head -n 5
          else
            secret_status="ok"
            printf 'No leaks found.\n'
          fi
        else
          secret_status="ok"
          printf 'gitleaks produced no findings.\n'
        fi
        [ -f "$tmpf" ] && rm -f "$tmpf"
      fi
    else
      printf 'gitleaks not installed — falling back to simple grep.\n'
      secret_status="fallback-grep"
      secret_output_json=$(git rev-list --max-count=200 --all 2>/dev/null | xargs -n1 -I{} git grep -I --line-number -e "password" -e "secret" -e "token" -e "key" {} 2>/dev/null | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || printf '%s' '[]')
      if [ "$secret_output_json" = "[]" ]; then
        printf 'No simple matches.\n'
      else
        printf 'Matches found (showing first 5):\n'
        printf '%s\n' "$(printf '%s' "$secret_output_json" | jq -r '.[]' 2>/dev/null | head -n 5 || echo 'Error parsing grep output.')"
      fi
    fi

    printf '\n2) Large files and LFS Status (Top 10):\n'
    if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1 2>/dev/null; then
      lfs_status="yes"
      printf 'Git LFS is ACTIVE. Tracked files: %s\n' "$(git lfs ls-files 2>/dev/null | wc -l | xargs || echo 0)"
    fi

    while IFS=' ' read -r size path; do
      [ -z "$size" ] && continue
      local human_size
      human_size=$(numfmt_or_human "$size")
      printf '%s %s\n' "$human_size" "$path"
      local entry
      entry=$(printf '{"size_bytes":%s,"size_human":"%s","path":"%s"}' "$size" "$human_size" "$(printf '%s' "$path" | sed 's/"/\\"/g')")
      printf '%s\n' "$entry" >> "$lf_tmp"
    done < <(
      git rev-list --objects --all 2>/dev/null |
      git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' 2>/dev/null |
      awk '/^blob/ {print $3, $4}' |
      sort -rn |
      head -n 10
    )

    printf '\n3) Branch Divergence Check (commits not on origin/%s):\n' "$PB"
    git for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null | grep -v '\->' | while IFS= read -r remote_branch; do
      [ -z "$remote_branch" ] && continue
      if [ "$remote_branch" = "origin/$PB" ]; then continue; fi
      local DIVERGED_COMMITS
      DIVERGED_COMMITS=$(git log --oneline "origin/$PB..$remote_branch" 2>/dev/null || true)
      if [ -n "$DIVERGED_COMMITS" ]; then
        local commit_count
        commit_count=$(printf '%s\n' "$DIVERGED_COMMITS" | wc -l | xargs)
        printf '  [DIVERGED] %s has %s unmerged commits.\n' "$remote_branch" "$commit_count"
        local commits_json
        commits_json=$(printf '%s\n' "$DIVERGED_COMMITS" | head -n 3 | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || '[]')
        local entry
        entry=$(jq -n --arg branch "$remote_branch" --argjson commits "$commits_json" --arg cnt "$commit_count" '{branch:$branch,unmerged_count:($cnt|tonumber),latest_commits:$commits,status:"diverged"}' 2>/dev/null || printf '%s' '{}')
        printf '%s\n' "$entry" >> "$div_tmp"
      fi
    done

    printf '\n4) Git Configuration Audit (Local):\n'
    git config --local --list | grep -E 'user|credential' || printf '(none)\n'
    printf '\n'
  } > "$human"

  if [ -s "$lf_tmp" ]; then
    large_files_json=$(jq -s '.' "$lf_tmp" 2>/dev/null || printf '[]')
  fi
  if [ -s "$div_tmp" ]; then
    divergence_json=$(jq -s '.' "$div_tmp" 2>/dev/null || printf '[]')
  fi
  [ -f "$lf_tmp" ] && rm -f "$lf_tmp"
  [ -f "$div_tmp" ] && rm -f "$div_tmp"

  jq -n \
    --arg pb "$PB" \
    --arg time "$audit_time" \
    --arg secret_status "$secret_status" \
    --argjson secret_output "$secret_output_json" \
    --arg lfs "$lfs_status" \
    --argjson large_files "$large_files_json" \
    --argjson divergence "$divergence_json" \
    '{primary_branch:$pb, time:$time, secret_scan:{status:$secret_status, output:$secret_output}, lfs_status:$lfs, large_files:$large_files, branch_divergence:$divergence}' > "$json" 2>/dev/null || printf '%s\n' '{"error":"failed-to-build-json"}' > "$json"

  _log info "Security audit complete. Reports: $human, $json"
  [ "${JSON_OUT:-0}" -eq 1 ] && cat "$json"
}

git_workflow_optimizer() {
  _log info "Running Git Workflow Optimizer..."
  local human="./git_workflow_optimizer_report.txt"
  local json="./git_workflow_optimizer_report.json"
  : > "$human"
  : > "$json"

  local total_remote_branches=0
  local total_commits=0
  local repo_size="unknown"

  {
    printf '=== Git Workflow Optimizer (%s) ===\n' "$(date '+%F %T')"
    printf '1) Performing garbage collection and compression...\n'
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
      printf '[DRY-RUN] git gc --aggressive --prune=now\n'
    else
      run_or_dry "git gc --aggressive --prune=now" || true
    fi

    printf '\n2) Applying local repository configuration for performance...\n'
    run_or_dry "git config --local core.compression 0"
    run_or_dry "git config --local core.loosecompression 0"
    run_or_dry "git config --local pack.windowMemory \"1g\""
    run_or_dry "git config --local pack.packSizeLimit 2g"

    printf '\n3) Cleaning up merged local branches...\n'
    local PB
    PB=$(primary_branch)
    git branch --merged "$PB" 2>/dev/null | grep -Ev "^[* ]($PB|master|develop|trunk)$" | while IFS= read -r branch_name; do
      branch_name=$(printf '%s' "$branch_name" | xargs)
      [ -z "$branch_name" ] && continue
      printf '  Deleting merged branch: %s\n' "$branch_name"
      run_or_dry "git branch -d \"$branch_name\"" || true
    done

    printf '\n4) Pruning stale remote tracking branches...\n'
    run_or_dry "git remote prune origin" || true

    printf '\n5) Generating workflow metrics...\n'
    total_remote_branches=$(git branch -r 2>/dev/null | wc -l | xargs || echo 0)
    total_commits=$(git rev-list --count HEAD 2>/dev/null | xargs || echo 0)
    repo_size=$(du -sh .git 2>/dev/null | awk '{print $1}' || echo "unknown")

    printf 'Total remote branches: %s\n' "$total_remote_branches"
    printf 'Total commits: %s\n' "$total_commits"
    printf 'Repo size: %s\n' "$repo_size"

    printf '\nCommit Frequency (Top 5):\n'
    git log --date=short --pretty=format:"%ad" 2>/dev/null | sort | uniq -c | sort -rn | head -n 5

    printf '\nTop 5 Contributors:\n'
    git shortlog -sn 2>/dev/null | head -n 5

  } > "$human"

  jq -n --arg remote_branches "$total_remote_branches" --arg commits "$total_commits" --arg repo_size "$repo_size" \
    '{total_remote_branches:($remote_branches|tonumber?//0), total_commits:($commits|tonumber?//0), repo_size:$repo_size}' > "$json" 2>/dev/null || printf '%s\n' '{}' > "$json"

  _log info "Optimization complete. Reports: $human, $json"
  [ "${JSON_OUT:-0}" -eq 1 ] && cat "$json"
}

local_snapshot() {
  _log info "Running Local Repository Snapshot..."
  if [ ! -d "${WORKDIR:-.}" ]; then
    _log error "Workdir ${WORKDIR} does not exist"
    return 1
  fi

  check_repo_size

  local DATE_TAG
  DATE_TAG=$("${DATE_CMD:-date}" '+%Y%m%d_%H%M%S' 2>/dev/null || date '+%Y%m%d_%H%M%S')
  local base_name="${SCRIPT_NAME%%.*}_${DATE_TAG}"
  local snapshot_file="${SNAPSHOT_DIR}/${base_name}.tar.gz"
  local snapshot_checksum="${SNAPSHOT_DIR}/${base_name}.sha256"

  local EXCLUDE_PATTERNS=(
    --exclude='.git'
    --exclude='node_modules'
    --exclude='venv'
    --exclude='__pycache__'
    --exclude='*.o'
    --exclude='*.pyc'
    --exclude='*.swp'
    --exclude='*.bak'
    --exclude='*.tmp'
    --exclude='*.log'
    --exclude='Thumbs.db'
    --exclude='.DS_Store'
  )

  _log info "Target snapshot file: ${snapshot_file}"
  local -a tar_args=( -czf "${snapshot_file}" )
  tar_args+=( "${EXCLUDE_PATTERNS[@]}" . )

  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    _log info "[DRY-RUN] ${TAR_CMD:-tar} ${tar_args[*]}"
  else
    ( cd "${WORKDIR}" && "${TAR_CMD:-tar}" "${tar_args[@]}" ) || {
      _log error "Snapshot tar creation failed."
      return 1
    }
    if [ -n "${SHA256SUM_CMD}" ]; then
      if command -v "${SHA256SUM_CMD%% *}" >/dev/null 2>&1; then
        "${SHA256SUM_CMD}" "${snapshot_file}" > "${snapshot_checksum}" 2>/dev/null || {
          _log warn "Failed to generate checksum with ${SHA256SUM_CMD}"
        }
      fi
    else
      if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "${snapshot_file}" > "${snapshot_checksum}" 2>/dev/null || _log warn "Failed to generate checksum with shasum"
      else
        _log warn "No sha256sum/shasum command available; skipping checksum."
      fi
    fi

    local size_bytes
    size_bytes=$(safe_stat_size "${snapshot_file}" || echo 0)
    _log info "Snapshot created: ${snapshot_file} (size: $(numfmt_or_human "$size_bytes"))"

    if [ "${size_bytes:-0}" -gt "${SNAPSHOT_MAX_BYTES}" ]; then
      _log warn "Snapshot size ($(numfmt_or_human "$size_bytes")) exceeds $(numfmt_or_human "$SNAPSHOT_MAX_BYTES"); consider storing externally."
    fi

    prune_snapshots
  fi

  return 0
}

restore_snapshot() {
  local sel="${1:-latest}"
  local target_dir=""
  set -- "${@:-$sel}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --target) shift; target_dir="${1:-}"; shift ;;
      --target=*) target_dir="${1#*=}"; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      latest) sel="latest"; shift ;;
      *) sel="$1"; shift ;;
    esac
  done

  if [ ! -d "${SNAPSHOT_DIR}" ]; then
    _log error "Snapshot directory not found: ${SNAPSHOT_DIR}"
    return 1
  fi

  list_snapshots() {
    if command -v find >/dev/null 2>&1 && command -v sort >/dev/null 2>&1; then
      find "${SNAPSHOT_DIR}" -maxdepth 1 -type f -name "${SCRIPT_NAME%%.*}_*.tar.gz" -printf '%T@ %p\n' 2>/dev/null | sort -n -r | awk '{print $2}'
    else
      ls -1t "${SNAPSHOT_DIR}/${SCRIPT_NAME%%.*}"_*.tar.gz 2>/dev/null || true
    fi
  }

  mapfile -t snaps < <(list_snapshots)

  if [ "${#snaps[@]}" -eq 0 ]; then
    _log warn "No snapshots found in ${SNAPSHOT_DIR}"
    return 2
  fi

  local snapshot_file=""
  if [ "${sel:-}" = "latest" ]; then
    snapshot_file="${snaps[0]}"
  else
    for s in "${snaps[@]}"; do
      if [ "$s" = "${sel}" ] || [ "$(basename "$s")" = "${sel}" ]; then
        snapshot_file="$s"
        break
      fi
    done
    if [ -z "$snapshot_file" ]; then
      _log error "Snapshot not found: ${sel}"
      _log info "Available snapshots:"
      for s in "${snaps[@]}"; do
        _log info "  $(basename "$s")"
      done
      return 3
    fi
  fi

  local checksum_file="${snapshot_file%.tar.gz}.sha256"
  if [ ! -f "${snapshot_file}" ]; then
    _log error "Snapshot file missing: ${snapshot_file}"
    return 4
  fi

  if [ -z "${target_dir}" ]; then
    local ts
    ts=$("${DATE_CMD:-date}" '+%Y%m%d_%H%M%S' 2>/dev/null || date '+%Y%m%d_%H%M%S')
    target_dir="./restored_${ts}"
  fi

  if [ -e "${target_dir}" ] && [ "$(ls -A "${target_dir}" 2>/dev/null | wc -l)" -gt 0 ]; then
    _log error "Target directory exists and is not empty: ${target_dir}"
    return 5
  fi

  _log info "Selected snapshot: ${snapshot_file}"
  _log info "Target directory: ${target_dir}"

  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    _log info "[DRY-RUN] Would verify checksum and extract snapshot into ${target_dir}"
    return 0
  fi

  if [ -f "${checksum_file}" ]; then
    _log info "Verifying checksum using: ${checksum_file}"
    if command -v sha256sum >/dev/null 2>&1; then
      if ! sha256sum -c "${checksum_file}" --status; then
        _log error "Checksum verification failed for ${snapshot_file}"
        return 6
      fi
    elif command -v shasum >/dev/null 2>&1; then
      local computed expected
      computed=$((shasum -a 256 "${snapshot_file}" 2>/dev/null) | awk '{print $1}')
      expected=$((awk '{print $1}' "${checksum_file}" 2>/dev/null) || echo "")
      if [ -z "${expected}" ] || [ "${computed}" != "${expected}" ]; then
        _log error "Checksum mismatch. Aborting."
        return 6
      fi
    fi
  else
    _log warn "Checksum file not found: ${checksum_file}; proceeding without verification."
  fi

  mkdir_p "${target_dir}"
  _log info "Extracting ${snapshot_file} -> ${target_dir}"
  if ! tar -xzf "${snapshot_file}" -C "${target_dir}"; then
    _log error "Extraction failed."
    return 7
  fi

  if command -v chown >/dev/null 2>&1; then
    local uid gid
    uid=$(id -u 2>/dev/null || echo "")
    gid=$(id -g 2>/dev/null || echo "")
    if [ -n "${uid}" ] && [ -n "${gid}" ]; then
      chown -R "${uid}:${gid}" "${target_dir}" 2>/dev/null || true
    fi
  fi

  _log info "Restore completed: ${target_dir}"
  return 0
}

setup_pre_commit_hook() {
  _log info "Setting up pre-commit hook..."
  local hook_file=".git/hooks/pre-commit"
  local hook_manager="${SCRIPT_NAME%%.*}"

  if [ ! -d .git ]; then
    _log error "Not a git repository."
    return 1
  fi

  if [ -f "${hook_file}" ]; then
    if grep -q "Managed by ${hook_manager}" "${hook_file}" 2>/dev/null; then
      _log info "Pre-commit hook already installed and managed."
      return 0
    else
      _log warn "Existing unmanaged pre-commit hook present; appending managed checks."
      if [ "${DRY_RUN:-0}" -eq 1 ]; then
        return 0
      fi
      cat >> "${hook_file}" <<EOF_MANAGED

# --- Managed by ${hook_manager} (appended) ---
set -euo pipefail
MAX_BYTES=${LARGE_FILE_LIMIT_BYTES}
git diff --cached --name-only -z | xargs -0 -I{} bash -c '
  for f; do
    [ -f "\$f" ] || continue
    if [ "\$(wc -c <"\$f" 2>/dev/null)" -gt \$MAX_BYTES ]; then
      echo "File is too large (>$(($MAX_BYTES/1024/1024))MB): \$f" >&2
      exit 1
    fi
  done
' bash {} || { echo "ERROR: Large staged file detected." >&2; exit 1; }
EOF_MANAGED
      chmod +x "${hook_file}"
      return 0
    fi
  fi

  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    return 0
  fi

  cat > "${hook_file}" <<EOF_HOOK
#!/usr/bin/env bash
# Managed by ${hook_manager}
set -euo pipefail

MAX_BYTES=${LARGE_FILE_LIMIT_BYTES}
git diff --cached --name-only -z | xargs -0 -I{} bash -c '
  for f; do
    [ -f "\$f" ] || continue
    if [ "\$(wc -c <"\$f" 2>/dev/null)" -gt \$MAX_BYTES ]; then
      echo "File is too large (>$((${LARGE_FILE_LIMIT_BYTES}/1024/1024))MB): \$f" >&2
      exit 1
    fi
  done
' bash {} || { echo "ERROR: Large staged file detected. Use git-lfs or remove from staging." >&2; exit 1; }
EOF_HOOK

  chmod +x "${hook_file}"
  _log info "Pre-commit hook installed in ${hook_file}"
  return 0
}

# ----------------------------------------------------------------------
# Usage & Dispatcher
# ----------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $SCRIPT_NAME <command> [--dry-run] [--json] [--workdir DIR] [--check]

Commands:
  dependency_master      - Updates dependencies based on lock files (npm, pip, etc.).
  git_security_audit     - Scans for secrets, large files, and branch divergence.
  git_workflow_optimizer - Performs garbage collection, prunes branches, and sets performance configs.
  local_snapshot         - Creates a compressed tarball snapshot of the working directory.
  restore_snapshot       - Restores a previously created snapshot (verify checksum, safe extract).
  setup_hooks            - Installs or appends managed pre-commit checks.

Options:
  --dry-run             Show commands without executing them.
  --json                Output results in JSON format.
  --workdir DIR         Specify the working directory.
  --check               Perform environment self-test.
EOF
  exit 2
}

# CLI Argument Parsing
ARGS=()
COMMAND=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --workdir)
      if [ -n "${2:-}" ] && [ -d "$2" ]; then
        WORKDIR="$2"
        shift 2
      else
        _log error "--workdir requires a valid directory"
        exit 1
      fi
      ;;
    --check) SELFTEST=1; shift ;;
    --) shift; break ;;
    -*)
      _log error "Unknown global option: $1"
      usage
      ;;
    *)
      if [ -z "$COMMAND" ]; then
        COMMAND="$1"
      else
        ARGS+=("$1")
      fi
      shift
      ;;
  esac
done

if [ -n "${WORKDIR:-}" ] && [ "${WORKDIR}" != "$(pwd)" ]; then
  cd "${WORKDIR}" || { _log error "Could not change to work directory ${WORKDIR}"; exit 3; }
fi

if [ "$SELFTEST" -eq 1 ]; then
  echo "Running self-test: checking required tools..."
  require_cmds git jq || { _log error "One or more required commands missing."; exit 4; }
  echo "All required commands present."
  exit 0
fi

case "${COMMAND:-}" in
  dependency_master) dependency_master "${ARGS[@]}" ;;
  git_security_audit) git_security_audit "${ARGS[@]}" ;;
  git_workflow_optimizer) git_workflow_optimizer "${ARGS[@]}" ;;
  local_snapshot) local_snapshot "${ARGS[@]}" ;;
  restore_snapshot) restore_snapshot "${ARGS[@]}" ;;
  setup_hooks) setup_pre_commit_hook "${ARGS[@]}" ;;
  ""|help|-h|--help) usage ;;
  *) _log error "Unknown command: ${COMMAND}"; usage; exit 2 ;;
esac

exit 0

