#!/usr/bin/env python3
"""super-board-config.py — read one value from a board config, the one way lanes do it.

    super-board-config.py get <key.path> --config <cfg.json> [--default <value>]

Prints a string or number as it is, true/false/null in JSON spelling, and an object
or array as compact JSON. A list index is a number in the path (`verify_commands.0`).
Lanes call this instead of `python3 -c "import json…"`: inline code can do anything,
so the permission decider stops it, while this script is one allowed call.

Exit: 0 printed · 3 key missing (and no --default) · 2 config unreadable · 64 usage.
"""
import json
import sys


def lookup(data, path):
    cur = data
    for part in path.split(".") if path else []:
        if isinstance(cur, dict) and part in cur:
            cur = cur[part]
        elif isinstance(cur, list) and part.isdigit() and int(part) < len(cur):
            cur = cur[int(part)]
        else:
            raise KeyError(path)
    return cur


def show(value):
    if isinstance(value, str):
        return value
    if isinstance(value, (dict, list)):
        return json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    return json.dumps(value)


def main(argv):
    args, config, default = [], None, None
    it = iter(argv)
    for a in it:
        if a == "--config":
            config = next(it, None)
        elif a == "--default":
            default = next(it, None)
        else:
            args.append(a)
    if len(args) != 2 or args[0] != "get" or not config:
        print(__doc__, file=sys.stderr)
        return 64
    try:
        data = json.load(open(config))
    except (OSError, ValueError) as e:
        print(f"super-board-config: cannot read {config}: {e}", file=sys.stderr)
        return 2
    try:
        print(show(lookup(data, args[1])))
    except KeyError:
        if default is None:
            print(f"super-board-config: {args[1]} not set in {config}", file=sys.stderr)
            return 3
        print(default)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
