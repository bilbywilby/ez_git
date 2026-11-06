#!/usr/bin/env python3
"""Disk usage profiler for Termux. Stdlib-only, read-only."""
import argparse, os, shutil, sys

def disk_overview(path):
    u = shutil.disk_usage(path)
    return {"total": u.total, "used": u.used, "free": u.free,
            "percent": round(u.used / u.total * 100, 1)}

def child_sizes(directory):
    out = []
    try:
        entries = os.listdir(directory)
    except OSError as e:
        print(f"warn: cannot list {directory}: {e}", file=sys.stderr)
        return []
    for name in entries:
        p = os.path.join(directory, name)
        try:
            size = os.path.getsize(p)
            if os.path.isdir(p):
                size = sum(os.path.getsize(os.path.join(r, f))
                           for r, _, fs in os.walk(p) for f in fs)
            out.append((name, size))
        except OSError:
            continue
    return sorted(out, key=lambda x: x[1], reverse=True)

def human(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB"):
        if n < 1024:
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TB"

def main():
    ap = argparse.ArgumentParser(description="Termux disk auditor (read-only)")
    ap.add_argument("--path", default=os.path.expanduser("~"))
    ap.add_argument("--top", type=int, default=10)
    ap.add_argument("--warn-percent", type=float, default=85.0)
    args = ap.parse_args()
    d = disk_overview(args.path)
    print(f"Disk: total {human(d['total'])} | used {human(d['used'])} "
          f"({d['percent']}%) | free {human(d['free'])}")
    if d["percent"] >= args.warn_percent:
        print(f"WARNING: disk at {d['percent']}%")
    print(f"\nTop {args.top} in {args.path}:")
    for name, size in child_sizes(args.path)[:args.top]:
        print(f"  {human(size):>10}  {name}")
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
