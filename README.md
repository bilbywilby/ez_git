cat > ~/projects/README.md << 'README1'
# git_superuser_workflow — Hardened Git toolkit for Termux

Hardened Git workflow toolkit for Termux / PuppyGit environments.

## Install

    pkg install git jq
    git clone https://github.com/bilbywilby/ez_git.git
    cd ez_git
    chmod +x git_superuser_workflow.sh

## Self-test

    ./git_superuser_workflow.sh --check

## Commands

    ./git_superuser_workflow.sh git_security_audit --dry-run   # secrets, big files, divergence
    ./git_superuser_workflow.sh git_workflow_optimizer          # safe GC + pruning
    ./git_superuser_workflow.sh local_snapshot                  # checksummed tarball backup
    ./git_superuser_workflow.sh restore_snapshot latest         # verified restore
    ./git_superuser_workflow.sh setup_hooks                     # 10MB pre-commit guard
    ./git_superuser_workflow.sh dependency_master --dry-run     # dependency updates

Always run with `--dry-run` first. Reports land in the current directory;
snapshots and logs in `~/.local/snapshots` and `~/.local/log/git_workflow`.

## Notes

- Snapshots exclude `.git` — push to a remote (like this repo) for history backup.
- GC settings are tuned for phones: single-threaded, 128m pack window.
- v2026.11.06: fixed premature exits under `set -e`, dry-run side effects.
README1
echo "All 3 parts written to ~/projects/"
