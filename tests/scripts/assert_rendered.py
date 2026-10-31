#!/usr/bin/env python3
"""Assert rendered Xray configs use keys Xray actually reads.

`xray -test` only validates what it recognises: a misplaced or misspelled key
is silently discarded, so a config can be "OK" and still do nothing. The
finalmask block lived under the freedom outbound's `settings` (instead of
`streamSettings`) with a `tcpmasks` list (instead of `tcp`) for months and
tested green the whole time. These checks catch that class of mistake.

Usage: assert_rendered.py <rendered-conf-dir> [<rendered-conf-dir> ...]
"""
import json
import pathlib
import sys

# Keys that no longer exist (or never did) anywhere in an Xray config.
# key -> what to use instead.
DEAD_KEYS = {
    "tcpmasks": "finalmask.tcp",
    "udpmasks": "finalmask.udp",
}

errors = []


def walk(node, path, on_object):
    if isinstance(node, dict):
        on_object(node, path)
        for k, v in node.items():
            walk(v, f"{path}.{k}", on_object)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, f"{path}[{i}]", on_object)


def check_file(f):
    doc = json.loads(f.read_text())

    def on_object(obj, path):
        for dead, instead in DEAD_KEYS.items():
            if dead in obj:
                errors.append(f"{f.name}: {path}.{dead} is not read by Xray — use {instead}")

        # Finalmask is a stream setting. Under `settings` it is dead config.
        if "finalmask" in obj and not path.endswith("streamSettings"):
            errors.append(
                f"{f.name}: {path}.finalmask is not read by Xray — "
                f"finalmask belongs to streamSettings"
            )

        # Finalmask entries are {type, settings} pairs.
        if path.endswith("streamSettings.finalmask"):
            for side in ("tcp", "udp"):
                for i, mask in enumerate(obj.get(side) or []):
                    if not isinstance(mask, dict) or "type" not in mask:
                        errors.append(
                            f"{f.name}: {path}.{side}[{i}] must be a "
                            f'{{"type": ..., "settings": {{...}}}} entry'
                        )

        # Finalmask's fragment mask takes `delay`; `interval` is the legacy
        # freedom.settings.fragment field and is ignored here.
        if obj.get("type") == "fragment" and "interval" in (obj.get("settings") or {}):
            errors.append(
                f"{f.name}: {path}.settings.interval is ignored by the "
                f"fragment mask — use delay"
            )

    walk(doc, f.stem, on_object)


def main():
    dirs = [pathlib.Path(d) for d in sys.argv[1:]]
    if not dirs:
        print(__doc__)
        return 2

    files = sorted(f for d in dirs for f in d.glob("*.json"))
    if not files:
        print(f"ERROR: no rendered configs found in {', '.join(map(str, dirs))}")
        return 1
    for f in files:
        check_file(f)

    if errors:
        print("FAIL: rendered config contains keys Xray does not read:")
        for e in errors:
            print(f"  - {e}")
        return 1

    print(f"OK: {len(files)} rendered config(s) use keys Xray reads.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
