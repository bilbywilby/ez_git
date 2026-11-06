# ez_git - Termux Housekeeping Toolkit

Zero-dependency toolkit for Android/Termux: disk auditing and safe
space reclamation. Every destructive tool supports --dry-run.

## Quickstart

    python3 src/space_audit.py --top 10     # see what is eating disk
    bash src/cleanup_reclaim.sh --dry-run   # preview, change nothing
    bash src/cleanup_reclaim.sh             # interactive, confirm each

## Components

- src/space_audit.py - read-only disk profiler, Python stdlib only
- src/cleanup_reclaim.sh - candidate-list reclaimer, per-item confirm
- src/cleanup_bighunt.sh - drill-down into heavy directories

## Design

Lean path: bash + Python stdlib, no pip dependencies. Dry-run is
first-class on destructive tools. Secrets never committed.
