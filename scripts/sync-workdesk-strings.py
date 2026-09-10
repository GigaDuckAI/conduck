#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Check or synchronize Work desk English copy from a fresh app compilation.

Xcode's GeneratedStringSymbols metadata describes generated accessors, not the
authored fallback text. It can contain only a key or bare format placeholder.
Only compiler records naming current files inside this app's source directory
are eligible. Missing, stale or conflicting defaults refuse the entire write.
Existing formatting, translations and metadata remain intact.

Usage: python3 scripts/sync-workdesk-strings.py --objects <app Objects-normal/arm64>
Add --write to synchronize after checking the proposed source defaults.
"""

import argparse
import json
import os
from pathlib import Path
import re
import tempfile


class CatalogError(ValueError):
    pass


KEY_PATTERN = re.compile(r'"(workdesk\.[A-Za-z0-9._]+)"')
TUTORIAL_KEY = "workboard.tutorial.point.arrange"
FORMAT_PATTERN = re.compile(r"%(?:\d+\$)?[-+#0 ]*(?:\d+)?(?:\.\d+)?(?:ll|l|h|z)?[@diuoxXfFeEgGsc%]")


def expected_keys(source_root):
    keys = set()
    for path in source_root.rglob("*.swift"):
        source = path.read_text()
        keys.update(KEY_PATTERN.findall(source))
        if f'"{TUTORIAL_KEY}"' in source:
            keys.add(TUTORIAL_KEY)
    if not keys:
        raise CatalogError("No authored Work desk strings found; check the source directory.")
    return keys


def collect_defaults(source_root, object_roots):
    source_root = source_root.resolve()
    expected = expected_keys(source_root)
    defaults = {}
    for object_root in object_roots:
        for path in sorted(object_root.glob("*.stringsdata")):
            if path.name.startswith("GeneratedStringSymbols"):
                continue
            record = json.loads(path.read_text())
            source = Path(record.get("source", "")).resolve()
            if not source.is_relative_to(source_root) or not source.is_file():
                continue
            entries = [entry for entry in record.get("tables", {}).get("Localizable", [])
                       if entry.get("key") in expected]
            if entries and source.stat().st_mtime_ns > path.stat().st_mtime_ns:
                raise CatalogError(f"Stale compiler metadata for {source.name}; rebuild first.")
            for entry in entries:
                key = entry["key"]
                value = entry.get("value")
                if not isinstance(value, str) or not value.strip() or value == key:
                    raise CatalogError(f"Missing authored default for {key}; no key fallback is allowed.")
                if not FORMAT_PATTERN.sub("", value).strip():
                    raise CatalogError(f"Placeholder-only default for {key}; rebuild from authored source.")
                if key in defaults and defaults[key] != value:
                    raise CatalogError(f"Conflicting authored defaults for {key}.")
                defaults[key] = value
    missing = expected - defaults.keys()
    if missing:
        raise CatalogError("Missing compiler defaults: " + ", ".join(sorted(missing)))
    return defaults


def member_span(text, name, start=0):
    """Find one JSON object member without matching a similarly named child."""
    decoder = json.JSONDecoder()
    cursor = start
    while text[cursor].isspace():
        cursor += 1
    if text[cursor] != "{":
        raise CatalogError(f"Expected an object containing {name}.")
    cursor += 1
    while True:
        while text[cursor].isspace():
            cursor += 1
        if text[cursor] == "}":
            return None
        key, cursor = decoder.raw_decode(text, cursor)
        while text[cursor].isspace():
            cursor += 1
        if text[cursor] != ":":
            raise CatalogError("Malformed catalog object.")
        cursor += 1
        while text[cursor].isspace():
            cursor += 1
        value_start = cursor
        _, cursor = decoder.raw_decode(text, cursor)
        if key == name:
            return value_start, cursor
        while text[cursor].isspace():
            cursor += 1
        if text[cursor] == ",":
            cursor += 1
        elif text[cursor] == "}":
            return None


def patched_catalog(text, defaults):
    catalog = json.loads(text)
    if catalog.get("sourceLanguage") != "en":
        raise CatalogError("This synchronizer requires an English source catalog.")
    strings_span = member_span(text, "strings")
    if strings_span is None:
        raise CatalogError("Missing catalog strings object.")
    edits = []
    additions = []
    changed = []
    for key, value in sorted(defaults.items()):
        entry = catalog["strings"].get(key)
        if entry is None:
            additions.append((key, value))
            changed.append(key)
            continue
        unit = entry.get("localizations", {}).get("en", {}).get("stringUnit")
        if not isinstance(unit, dict) or "value" not in unit:
            raise CatalogError(f"{key} needs a manual English translation update; structured entries are preserved.")
        if unit["value"] == value:
            continue
        span = strings_span
        for component in (key, "localizations", "en", "stringUnit", "value"):
            span = member_span(text, component, span[0])
            if span is None:
                raise CatalogError(f"Missing translation value for {key}.")
        edits.append((span[0], span[1], json.dumps(value, ensure_ascii=False)))
        changed.append(key)
    for start, end, replacement in sorted(edits, reverse=True):
        text = text[:start] + replacement + text[end:]
    if additions:
        rendered = []
        for key, value in additions:
            entry = {"extractionState": "manual", "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": value}}}}
            lines = json.dumps(entry, ensure_ascii=False, indent=2, separators=(",", " : ")).splitlines()
            rendered.append("    " + json.dumps(key) + " : " + lines[0] + "\n"
                            + "\n".join("    " + line for line in lines[1:]))
        opening = member_span(text, "strings")[0] + 1
        suffix = "," if catalog["strings"] else ""
        text = text[:opening] + "\n" + ",\n".join(rendered) + suffix + text[opening:]
    json.loads(text)
    return text, changed


def synchronize(catalog_path, source_root, object_roots, write=False):
    defaults = collect_defaults(source_root, object_roots)
    updated, changed = patched_catalog(catalog_path.read_text(), defaults)
    if write and changed:
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=catalog_path.parent,
                                             prefix=".workdesk-strings-", delete=False) as output:
                temporary = Path(output.name)
                output.write(updated)
            os.chmod(temporary, catalog_path.stat().st_mode)
            os.replace(temporary, catalog_path)
        finally:
            if temporary is not None and temporary.exists():
                temporary.unlink()
    return changed


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--objects", type=Path, nargs="+", required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--write", action="store_true")
    modes.add_argument("--check", action="store_true", help="Default: check without writing.")
    args = parser.parse_args()
    try:
        changed = synchronize(repo / "Conduck/Conduck/Localizable.xcstrings",
            repo / "Conduck/Conduck", args.objects, write=args.write)
    except (CatalogError, OSError, ValueError) as error:
        parser.exit(2, f"Work desk localization check failed: {error}\n")
    if changed and not args.write:
        parser.exit(1, "English copy differs from authored defaults: " + ", ".join(changed) + "\n")
    print(f"Work desk English copy {'updated' if args.write else 'verified'}; {len(changed)} changed values.")


if __name__ == "__main__":
    main()
