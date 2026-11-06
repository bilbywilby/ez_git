cat >> ~/projects/git_superuser_workflow.sh << 'GSW2'

git_security_audit() {
  if ! command -v jq >/dev/null 2>&1; then
    _log error "'jq' is required for security audit. Try: pkg install jq"
    exit 1
  fi
  _log info "Running Git Security Audit..."
  local human="./git_security_audit_report.txt"
  local json="./git_security_audit_report.json"
  : > "$human"

  local PB
  PB=$(primary_branch)
  local audit_time
  audit_time=$(date '+%F %T')

  local secret_status="skipped"
  local secret_output_json='[]'
  local lfs_status="no"
  local large_files_json='[]'
  local divergence_json='[]'

  local lf_tmp div_tmp
  lf_tmp="$(mktemp_dir)/large_files.$$.json"
  div_tmp="$(mktemp_dir)/divergence.$$.json"
  : > "$lf_tmp"; : > "$div_tmp"

  {
    printf '=== Git Security Audit (%s) ===\n' "$audit_time"
    printf 'Primary branch: %s\n\n' "$PB"

    printf '1) Secret-pattern scan (recent 200 commits):\n'
    if command -v gitleaks >/dev/null 2>&1; then
      if [ "${DRY_RUN:-0}" -eq 1 ]; then
        printf '[DRY-RUN] gitleaks detect --report-format json --max-count=200\n'
        secret_status="dry-run"
      else
        local tmpf
        tmpf="$(mktemp_dir)/gitleaks.$$.json"
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
            secret_status="ok"; printf 'No leaks found.\n'
          fi
        else
          secret_status="ok"; printf 'gitleaks produced no findings.\n'
        fi
        rm -f "$tmpf"
      fi
    else
      printf 'gitleaks not installed — skipping deep scan (install with: pkg install gitleaks).\n'
      secret_status="skipped-no-tool"
    fi

    printf '\n2) Large files and LFS status (Top 10):\n'
    if git lfs version >/dev/null 2>&1; then
      lfs_status="yes"
      printf 'Git LFS is ACTIVE. Tracked files: %s\n' "$(git lfs ls-files 2>/dev/null | wc -l)"
    fi
    local size path human_size
    while IFS=' ' read -r size path; do
      [ -z "${size:-}" ] && continue
      human_size=$(numfmt_or_human "$size")
      printf '%s %s\n' "$human_size" "$path"
      printf '{"size_bytes":%s,"size_human":"%s","path":"%s"}\n' "$size" "$human_size" \
        "$(printf '%s' "$path" | sed 's/"/\\"/g')" >> "$lf_tmp"
    done < <(
      git rev-list --objects --all 2>/dev/null |
      git cat-file --batch-check='%(objecttype) %(objectname) %(objectsize) %(rest)' 2>/dev/null |
      awk '/^blob/ {print $3, $4}' | sort -rn | head -n 10
    )

    printf '\n3) Branch divergence vs origin/%s:\n' "$PB"
    git for-each-ref --format='%(refname:short)' refs/remotes/origin 2>/dev/null | grep -v '\->' |
    while IFS= read -r remote_branch; do
      [ -z "$remote_branch" ] && continue
      if [ "$remote_branch" = "origin/$PB" ]; then continue; fi
      local dc
      dc=$(git log --oneline "origin/$PB..$remote_branch" 2>/dev/null || true)
      if [ -n "$dc" ]; then
        printf '  [DIVERGED] %s has %s unmerged commits.\n' "$remote_branch" "$(printf '%s\n' "$dc" | wc -l)"
        local cj
        cj=$(printf '%s\n' "$dc" | head -n 3 | jq -R -s 'split("\n") | map(select(length>0))' 2>/dev/null || '[]')
        jq -n --arg branch "$remote_branch" --argjson commits "$cj" \
          --argjson cnt "$(printf '%s\n' "$dc" | wc -l)" \
          '{branch:$branch,unmerged_count:$cnt,latest_commits:$commits,status:"diverged"}' \
          >> "$div_tmp" 2>/dev/null || true
      fi
    done

    printf '\n4) Git configuration audit (local):\n'
    git config --local --list | grep -E 'user|credential' || printf '(none)\n'
  } > "$human"

  if [ -s "$lf_tmp" ]; then large_files_json=$(jq -s '.' "$lf_tmp" 2>/dev/null || printf '[]'); fi
  if [ -s "$div_tmp" ]; then divergence_json=$(jq -s '.' "$div_tmp" 2>/dev/null || printf '[]'); fi
  rm -f "$lf_tmp" "$div_tmp"

  jq -n \
    --arg pb "$PB" --arg time "$audit_time" \
    --arg secret_status "$secret_status" --argjson secret_output "$secret_output_json" \
    --arg lfs "$lfs_status" --argjson large_files "$large_files_json" \
    --argjson divergence "$divergence_json" \
    '{primary_branch:$pb,time:$time,secret_scan:{status:$secret_status,output:$secret_output},lfs_status:$lfs,large_files:$large_files,branch_divergence:$divergence}' \
    > "$json" 2>/dev/null || printf '%s\n' '{"error":"failed-to-build-json"}' > "$json"

  _log info "Security audit complete. Reports: $human, $json"
  emit_json "$json"
}

git_workflow_optimizer() {
  _log info "Running Git Workflow Optimizer..."
  local human="./git_workflow_optimizer_report.txt"
  local json="./git_workflow_optimizer_report.json"
  : > "$human"

  local total_remote_branches=0 total_commits=0 repo_size="unknown"

  {
    printf '=== Git Workflow Optimizer (%s) ===\n' "$(date '+%F %T')"
    printf '1) Garbage collection (mobile-safe: no aggressive, no prune=now)...\n'
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
      printf '[DRY-RUN] git gc\n'
    else
      run_or_dry "git gc" || true
    fi

    printf '\n2) Mobile-appropriate pack settings...\n'
    run_or_dry "git config --local pack.threads 1"
    run_or_dry "git config --local pack.windowMemory 128m"

    printf '\n3) Cleaning up merged local branches...\n'
    local PB
    PB=$(primary_branch)
    git branch --merged "$PB" 2>/dev/null | grep -Ev "^[* ]+($PB|master|develop|trunk)$" |
    while IFS= read -r branch_name; do
      branch_name=$(printf '%s' "$branch_name" | xargs)
      [ -z "$branch_name" ] && continue
      printf '  Deleting merged branch: %s\n' "$branch_name"
      run_or_dry "git branch -d \"$branch_name\"" || true
    done

    printf '\n4) Pruning stale remote-tracking branches...\n'
    run_or_dry "git remote prune origin" || true

    printf '\n5) Workflow metrics...\n'
    total_remote_branches=$(git branch -r 2>/dev/null | wc -l)
    total_commits=$(git rev-list --count HEAD 2>/dev/null || echo 0)
    repo_size=$(du -sh .git 2>/dev/null | awk '{print $1}' || echo "unknown")

    printf 'Total remote branches: %s\n' "$total_remote_branches"
    printf 'Total commits: %s\n' "$total_commits"
    printf 'Repo size: %s\n' "$repo_size"
    printf '\nCommit frequency (top 5):\n'
    git log --date=short --pretty=format:"%ad" 2>/dev/null | sort | uniq -c | sort -rn | head -n 5
    printf '\nTop 5 contributors:\n'
    git shortlog -sn 2>/dev/null | head -n 5
  } > "$human"

  jq -n --arg remote_branches "$total_remote_branches" --arg commits "$total_commits" --arg repo_size "$repo_size" \
    '{total_remote_branches:($remote_branches|tonumber?//0),total_commits:($commits|tonumber?//0),repo_size:$repo_size}' \
    > "$json" 2>/dev/null || printf '%s\n' '{}' > "$json"

  _log info "Optimization complete. Reports: $human, $json"
  emit_json "$json"
}

local_snapshot() {
  _log info "Running Local Repository Snapshot..."
  if [ ! -d "${WORKDIR:-.}" ]; then
    _log error "Workdir ${WORKDIR} does not exist"
    return 1
  fi
  check_repo_size

  local DATE_TAG
  DATE_TAG=$("${DATE_CMD:-date}" '+%Y%m%d_%H%M%S')
  local base_name="${SCRIPT_NAME%%.*}_${DATE_TAG}"
  local snapshot_file="${SNAPSHOT_DIR}/${base_name}.tar.gz"
  local snapshot_checksum="${SNAPSHOT_DIR}/${base_name}.sha256"

  local -a EXCLUDE_PATTERNS=(
    --exclude='.git' --exclude='node_modules' --exclude='venv'
    --exclude='__pycache__' --exclude='*.o' --exclude='*.pyc'
    --exclude='*.swp' --exclude='*.bak' --exclude='*.tmp'
    --exclude='Thumbs.db' --exclude='.DS_Store'
  )
  # NOTE: *.log removed from excludes is intentionally NOT restored —
  # logs excluded to save space; .git excluded (use git push for history backup)

  _log info "Target snapshot file: ${snapshot_file}"
  local -a tar_args=( -czf "${snapshot_file}" "${EXCLUDE_PATTERNS[@]}" . )

  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    _log info "[DRY-RUN] ${TAR_CMD:-tar} ${tar_args[*]}"
  else
    ( cd "${WORKDIR}" && "${TAR_CMD:-tar}" "${tar_args[@]}" ) || {
      _log error "Snapshot tar creation failed."
      return 1
    }
    if [ -n "${SHA256SUM_CMD}" ]; then
      "${SHA256SUM_CMD}" "${snapshot_file}" > "${snapshot_checksum}" 2>/dev/null \
        || _log warn "Failed to generate checksum"
    else
      _log warn "No sha256sum/shasum available; skipping checksum."
    fi
    local size_bytes
    size_bytes=$(safe_stat_size "${snapshot_file}")
    _log info "Snapshot created: ${snapshot_file} (size: $(numfmt_or_human "$size_bytes"))"
    if [ "${size_bytes:-0}" -gt "${SNAPSHOT_MAX_BYTES}" ]; then
      _log warn "Snapshot exceeds $(numfmt_or_human "$SNAPSHOT_MAX_BYTES"); consider external storage."
    fi
    prune_snapshots
  fi
  return 0
}

restore_snapshot() {
  local sel="${1:-latest}" target_dir=""
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

  local -a snaps=()
  mapfile -t snaps < <(find "${SNAPSHOT_DIR}" -maxdepth 1 -type f -name "${SCRIPT_NAME%%.*}_*.tar.gz" -printf '%T@ %p\n' 2>/dev/null | sort -n -r | awk '{print $2}')
  if [ "${#snaps[@]}" -eq 0 ]; then
    _log warn "No snapshots found in ${SNAPSHOT_DIR}"
    return 2
  fi

  local snapshot_file="" s
  if [ "${sel:-}" = "latest" ]; then
    snapshot_file="${snaps[0]}"
  else
    for s in "${snaps[@]}"; do
      if [ "$s" = "$sel" ] || [ "$(basename "$s")" = "$sel" ]; then snapshot_file="$s"; break; fi
    done
    if [ -z "$snapshot_file" ]; then
      _log error "Snapshot not found: $sel"
      return 3
    fi
  fi

  local checksum_file="${snapshot_file%.tar.gz}.sha256"
  if [ ! -f "${snapshot_file}" ]; then
    _log error "Snapshot file missing: ${snapshot_file}"
    return 4
  fi

  if [ -z "$target_dir" ]; then
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    target_dir="./restored_${ts}"
  fi
  if [ -e "$target_dir" ] && [ "$(ls -A "$target_dir" 2>/dev/null | wc -l)" -gt 0 ]; then
    _log error "Target directory exists and is not empty: $target_dir"
    return 5
  fi

  _log info "Selected snapshot: $snapshot_file"
  _log info "Target directory: $target_dir"
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    _log info "[DRY-RUN] Would verify checksum and extract into $target_dir"
    return 0
  fi

  if [ -f "$checksum_file" ]; then
    _log info "Verifying checksum: $checksum_file"
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum -c "$checksum_file" --status || { _log error "Checksum verification failed."; return 6; }
    elif command -v shasum >/dev/null 2>&1; then
      local computed expected
      computed=$(shasum -a 256 "$snapshot_file" 2>/dev/null | awk '{print $1}')
      expected=$(awk '{print $1}' "$checksum_file" 2>/dev/null || echo "")
      if [ -z "$expected" ] || [ "$computed" != "$expected" ]; then
        _log error "Checksum mismatch. Aborting."; return 6
      fi
    fi
  else
    _log warn "No checksum file; proceeding without verification."
  fi

  mkdir_p "$target_dir"
  if ! tar -xzf "$snapshot_file" -C "$target_dir"; then
    _log error "Extraction failed."; return 7
  fi
  _log info "Restore completed: $target_dir"
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
  if [ -f "$hook_file" ] && grep -q "Managed by ${hook_manager}" "$hook_file" 2>/dev/null; then
    _log info "Pre-commit hook already installed and managed."
    return 0
  fi
  if [ "${DRY_RUN:-0}" -eq 1 ]; then
    _log info "[DRY-RUN] Would $([ -f "$hook_file" ] && echo append to || echo create) $hook_file"
    return 0
  fi
  cat >> "$hook_file" <<EOF_HOOK

# --- Managed by ${hook_manager} ---
if [ "\$(git diff --cached --name-only -z | xargs -0 -I{} bash -c 'for f; do [ -f "\$f" ] && [ "\$(wc -c <"\$f" 2>/dev/null)" -gt ${LARGE_FILE_LIMIT_BYTES} ] && { echo "Too large (>10MB): \$f" >&2; exit 1; }; done' bash {})" ]; then
  echo "ERROR: Large staged file detected. Use git-lfs or unstage." >&2
  exit 1
fi
EOF_HOOK
  chmod +x "$hook_file"
  _log info "Pre-commit hook installed in $hook_file"
  return 0
}

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME <command> [--dry-run] [--json] [--workdir DIR] [--check]

Commands:
  dependency_master      - Updates dependencies based on lock files (npm, pip, etc.).
  git_security_audit     - Scans for secrets, large files, and branch divergence.
  git_workflow_optimizer - GC, branch pruning, and mobile-safe pack config.
  local_snapshot         - Compressed tarball snapshot of the working directory.
  restore_snapshot       - Restores a snapshot (checksum-verified, safe extract).
  setup_hooks            - Installs or appends managed pre-commit checks.

Options:
  --dry-run | --json | --workdir DIR | --check
EOF
  exit 2
}

ARGS=()
COMMAND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --workdir)
      if [ -n "${2:-}" ] && [ -d "$2" ]; then WORKDIR="$2"; shift 2
      else _log error "--workdir requires a valid directory"; exit 1; fi
      ;;
    --check) SELFTEST=1; shift ;;
    --) shift; break ;;
    -*) _log error "Unknown global option: $1"; usage ;;
    *) if [ -z "$COMMAND" ]; then COMMAND="$1"; else ARGS+=("$1"); fi; shift ;;
  esac
done

# Directories created here — AFTER parsing (dry-run stays side-effect-free)
mkdir_p "${LOG_DIR}"
mkdir_p "${SNAPSHOT_DIR}"

if [ -n "${WORKDIR:-}" ] && [ "${WORKDIR}" != "$(pwd)" ]; then
  cd "${WORKDIR}" || { _log error "Could not change to work directory ${WORKDIR}"; exit 3; }
fi

if [ "$SELFTEST" -eq 1 ]; then
  echo "Running self-test: checking required tools..."
  if require_cmds git jq; then
    echo "All required commands present."
    exit 0
  else
    _log error "One or more required commands missing."
    exit 4
  fi
fi

case "${COMMAND:-}" in
  dependency_master)      dependency_master "${ARGS[@]:-}" ;;
  git_security_audit)     git_security_audit "${ARGS[@]:-}" ;;
  git_workflow_optimizer) git_workflow_optimizer "${ARGS[@]:-}" ;;
  local_snapshot)         local_snapshot "${ARGS[@]:-}" ;;
  restore_snapshot)       restore_snapshot "${ARGS[@]:-}" ;;
  setup_hooks)            setup_pre_commit_hook "${ARGS[@]:-}" ;;
  ""|help|-h|--help) usage ;;
  *) _log error "Unknown command: ${COMMAND}"; usage ;;
esac
exit 0
GSW2
chmod +x ~/projects/git_superuser_workflow.sh
bash -n ~/projects/git_superuser_workflow.sh && echo "Syntax OK"
