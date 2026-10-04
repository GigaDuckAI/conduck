#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Validate all shipped app catalogs for coverage and translation contracts.

Translations may reorder arguments, but must retain their positions and types.
Links must retain their destinations. Plural categories follow the target
language: Spanish requires one/other; Chinese and Japanese require other.
This checks catalog data, not linguistic quality or physical-device layout.
"""

from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
LANGUAGES = ("en", "es", "zh-Hans", "ja")
FORMAT = re.compile(r"%(?:(\d+)\$)?[-+#0 ]*(?:\d+|\*)?(?:\.(?:\d+|\*))?((?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSp]|#@[^@]+@|%)")
LINK = re.compile(r"\]\(([^)]+)\)")
VARIABLE = re.compile(r"\$\{[^}]+\}")


def arguments(value):
    tokens = []
    next_position = 1
    for match in FORMAT.finditer(value):
        position, kind = match.groups()
        if kind == "%":
            continue
        if position is None:
            position = next_position
            next_position += 1
        tokens.append((int(position), kind))
    return Counter(tokens)


def leaves(value, path=()):
    if "stringUnit" in value:
        yield path, value["stringUnit"]
    for key, child in value.items():
        if key != "stringUnit" and isinstance(child, dict):
            yield from leaves(child, path + (key,))


def validate():
    failures = []
    count = 0
    catalogs = sorted((ROOT / "Conduck").rglob("*.xcstrings"))
    for catalog in catalogs:
        data = json.loads(catalog.read_text())
        for key, entry in data["strings"].items():
            count += 1
            localizations = entry.get("localizations", {})
            english = dict(leaves(localizations.get("en", {"stringUnit": {"value": key}})))
            for language in LANGUAGES:
                label = f"{catalog.relative_to(ROOT)}: {key!r} [{language}]"
                if language == "en" and language not in localizations:
                    # Literal source-language keys need no explicit unit.
                    continue
                if language not in localizations:
                    failures.append(label + " missing translation")
                    continue
                translated = dict(leaves(localizations[language]))
                required = set(english)
                if language in ("zh-Hans", "ja"):
                    required = {path for path in required if "one" not in path}
                for path in required:
                    if path not in translated:
                        failures.append(label + f" missing variation {path}")
                for path, unit in translated.items():
                    value = unit.get("value")
                    allowed_states = ("translated", "new") if language == "en" else ("translated",)
                    if not isinstance(value, str) or (key and not value.strip()) or unit.get("state") not in allowed_states:
                        failures.append(label + f" incomplete string unit {path}")
                        continue
                    reference = english.get(path)
                    if reference is None and "one" in path:
                        reference = english.get(tuple("other" if p == "one" else p for p in path))
                    if reference is None:
                        failures.append(label + f" unknown variation {path}")
                        continue
                    source = reference["value"]
                    if arguments(value) != arguments(source):
                        failures.append(label + f" changed arguments {path}: {arguments(source)} -> {arguments(value)}")
                    if Counter(LINK.findall(value)) != Counter(LINK.findall(source)):
                        failures.append(label + f" changed link destinations {path}")
                    if Counter(VARIABLE.findall(value)) != Counter(VARIABLE.findall(source)):
                        failures.append(label + f" changed named interpolation variables {path}")
    if failures:
        print("\n".join(failures[:30]), file=sys.stderr)
        print(f"{len(failures)} localization contract failures", file=sys.stderr)
        return 1
    print(f"Localization contracts passed: {count} entries across {len(catalogs)} catalogs; all {len(LANGUAGES)} languages complete.")
    return 0


if __name__ == "__main__":
    sys.exit(validate())
