#!/bin/bash
# Plugin: git_workflow.sh
# Description: Integrates git_superuser_workflow capabilities (snapshots, restore, security audit, dependency master) into Termux Advanced Utility Framework.

run_git_workflow() {
    local workflow_script="${HOME}/Keystone_Health/git_superuser_workflow.sh"
    
    if [ ! -f "$workflow_script" ]; then
        cprint "❌ git_superuser_workflow.sh not found at expected path: $workflow_script" "31"
        return 1
    }

    cprint "\n--- Git Superuser Workflow Menu ---" "36"
    cprint "  1) Local Snapshot (tarball + SHA256)"
    cprint "  2) Restore Snapshot (latest or specific)"
    cprint "  3) Dependency Master (npm, pip, composer)"
    cprint "  4) Git Security Audit (secrets, large objects)"
    cprint "  5) Git Workflow Optimizer (gc, prune, perf config)"
    cprint "  6) Setup Pre-Commit Hooks"
    
    read -rp "Select workflow action (1-6): " action_choice

    case "$action_choice" in
        1) bash "$workflow_script" local_snapshot ;;
        2) 
           read -rp "Enter snapshot filename or 'latest' [latest]: " snap_target
           snap_target="${snap_target:-latest}"
           read -rp "Enter target directory [optional]: " target_dir
           if [ -n "$target_dir" ]; then
               bash "$workflow_script" restore_snapshot "$snap_target" --target "$target_dir"
           else
               bash "$workflow_script" restore_snapshot "$snap_target"
           fi
           ;;
        3) bash "$workflow_script" dependency_master ;;
        4) bash "$workflow_script" git_security_audit ;;
        5) bash "$workflow_script" git_workflow_optimizer ;;
        6) bash "$workflow_script" setup_hooks ;;
        *) cprint "Invalid selection." "31" ;;
    }
}

run_git_workflow_meta() {
    echo "Plugin: git_workflow"
    echo "Description: Manages repository snapshots, restorations, dependency updates, security audits, and optimizations via git_superuser_workflow."
    echo "Dependencies: bash, git, tar, jq"
}

