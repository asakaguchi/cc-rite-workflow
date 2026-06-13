#!/usr/bin/env python3
"""rite workflow - settings.local.json rite hook cleanup transform

Pure JSON transformation: reads .claude/settings.local.json from stdin, removes
every hook entry whose command references a rite hook (command path contains
`rite` as a full segment immediately above the hooks dir — see RITE_HOOK_RE),
and writes the cleaned JSON to stdout. Non-rite hooks are preserved. Hook events
left with no entries are dropped. No file I/O, no API calls — the atomic write is
handled by the calling bash wrapper (settings-local-rite-hook-cleanup.sh).

Used by commands/init.md Phase 4.5.0.2 when native hooks.json management is in
effect, to clear stale legacy rite hook registrations.

Usage:
    python3 settings-local-rite-hook-cleanup.py < settings.local.json > cleaned.json

Exit codes:
    0: rite hook entries removed — cleaned JSON written to stdout
    1: no change (no `hooks` section, or no rite hook entries) — nothing written
    2: stdin is not valid JSON — nothing written
"""
import json
import re
import sys

# Match `rite` only as a complete path segment directly above the hooks dir,
# allowing one optional segment (the plugin version) in between. This covers both
# real command shapes — cache install `.../rite-marketplace/rite/<version>/hooks/`
# and dev/relative `.../rite/hooks/` — while rejecting look-alikes where `rite` is
# merely a substring of another segment (`favorite/hooks/`, `prerite/hooks/`,
# `rite-something/hooks/`), which the old `rite.*?/hooks/` over-matched and could
# silently strip user-defined non-rite hooks from settings.local.json.
RITE_HOOK_RE = re.compile(r"(?:^|/)rite/(?:[^/]+/)?hooks/")


def main():
    try:
        data = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError):
        return 2

    hooks = data.get("hooks", {})
    if not hooks:
        return 1

    changed = False
    for event_name in list(hooks.keys()):
        entries = hooks[event_name]
        if not isinstance(entries, list):
            continue
        new_entries = []
        for entry in entries:
            hook_list = entry.get("hooks", [])
            has_rite = any(
                RITE_HOOK_RE.search(h.get("command", "")) for h in hook_list
            )
            if has_rite:
                changed = True
            else:
                new_entries.append(entry)
        if new_entries:
            hooks[event_name] = new_entries
        else:
            del hooks[event_name]

    if not changed:
        return 1

    json.dump(data, sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
