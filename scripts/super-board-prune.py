#!/usr/bin/env python3
"""Remove retired skills, bin scripts and workflows from a target project. install.sh runs it.

    super-board-prune.py <pack-root> <target> <host> [<host> ...]

The retired names come from the manifest (<pack-root>/skills/families.json → "retired").
A retired entry under .agents/ or a host folder (.claude/, .codex/, .opencode/) is removed
only when it is safe to say it is ours:

  - a name the pack itself shipped (a "standalone" skill, a retired bin script or workflow):
    a link that points into the target's .agents/ or into the pack, or a real copy. Left
    alone when skills-lock.json says another source owns that name.
  - any other retired skill: only when skills-lock.json lists it with a retired source
    (mattpocock/skills, cloudflare/security-audit-skill). That lock entry is dropped too.

Anything else (the owner's own skills, links elsewhere) is never touched. Folders that resolve
outside the target are never pruned. Everything removed, and skills-lock.json before it is
changed, is copied first to .claude/super-board/backup/<timestamp>/ with links kept as links.
A second run finds nothing and writes nothing. Prints one line per action group; stdlib only.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import shutil
import sys


def inside(path, root):
    path, root = os.path.realpath(path), os.path.realpath(root)
    return path == root or path.startswith(root + os.sep)


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 64
    pack, target, hosts = argv[0], argv[1], argv[2:]
    manifest = json.load(open(os.path.join(pack, "skills", "families.json")))
    retired = manifest["retired"]
    sources = set(retired.get("sources", []))
    shipped = set(manifest.get("standalone", {}).get("skills", {}))
    groups = [("skills", name) for name in retired["names"]]
    groups += [("bin", name) for name in retired.get("bin", [])]
    groups += [("workflows", name) for name in retired.get("workflows", [])]

    lock_path = os.path.join(target, "skills-lock.json")
    try:
        lock = json.load(open(lock_path))
    except (OSError, ValueError):
        lock = None
    locked = lock.get("skills") if isinstance(lock, dict) and isinstance(lock.get("skills"), dict) else {}

    def lock_source(name):
        entry = locked.get(name)
        return entry.get("source") if isinstance(entry, dict) else None

    shared = os.path.join(target, ".agents")
    folders = [".agents"] + ["." + h for h in hosts]
    remove, seen, drop = [], set(), []
    for group, name in groups:
        ours_by_name = group != "skills" or name in shipped
        source = lock_source(name) if group == "skills" else None
        if ours_by_name:
            if source and source not in sources:
                continue  # the owner took this name over from another source
        elif source not in sources:
            continue  # not installed by a retired source: the owner's own
        if group == "skills" and source in sources:
            drop.append(name)
        for folder in folders:
            parent = os.path.join(target, folder, group)
            path = os.path.join(parent, name)
            if not os.path.lexists(path) or not inside(parent, target):
                continue
            key = (os.path.realpath(parent), name)
            if key in seen:
                continue
            if ours_by_name and os.path.islink(path):
                dest = os.path.join(os.path.dirname(path), os.readlink(path))
                if not (inside(dest, shared) or inside(dest, pack)):
                    continue  # the owner's own link elsewhere
            seen.add(key)
            remove.append(path)

    if not remove and not drop:
        return 0
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    base = os.path.join(target, ".claude", "super-board", "backup", stamp)
    backup, n = base, 1
    while os.path.exists(backup):
        n += 1
        backup = f"{base}-{n}"
    for path in remove + ([lock_path] if drop else []):
        to = os.path.join(backup, os.path.relpath(path, target))
        os.makedirs(os.path.dirname(to), exist_ok=True)
        if os.path.islink(path):
            os.symlink(os.readlink(path), to)
        elif os.path.isdir(path):
            shutil.copytree(path, to, symlinks=True)
        else:
            shutil.copy2(path, to)
    for path in remove:
        if os.path.islink(path) or not os.path.isdir(path):
            os.unlink(path)  # a link is removed, never followed
        else:
            shutil.rmtree(path)
    if drop:
        for name in drop:
            locked.pop(name, None)
        with open(lock_path + ".tmp", "w") as f:
            json.dump(lock, f, indent=2)
            f.write("\n")
        os.replace(lock_path + ".tmp", lock_path)

    names = sorted({os.path.basename(p) for p in remove} | set(drop))
    rel = os.path.relpath(backup, target) + "/"
    print(f"   🧹 pruned {len(names)} retired: {', '.join(names)} (backup: {rel})")
    user_wide = retired.get("user_wide", "")
    if user_wide and set(names) & set(user_wide.replace(";", " ").split()):
        print(f"   💡 want them user-wide? {user_wide}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
