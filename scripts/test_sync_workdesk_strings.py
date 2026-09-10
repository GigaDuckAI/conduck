#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0

"""Regression coverage for generated-symbol contamination and atomic catalog edits.

Compiler-shaped fixtures encode the precise failure that replaced visible copy
with keys and dropped words around interpolations. App bundle XCTest coverage
checks the real compiler output independently of these tooling tests.
"""

import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("workdesk_strings", Path(__file__).with_name("sync-workdesk-strings.py"))
sync = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sync)


class WorkDeskStringSyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="conduck-string-sync-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "App"
        self.objects = self.root / "Objects"
        self.source.mkdir()
        self.objects.mkdir()
        self.catalog = self.root / "Localizable.xcstrings"

    def authored(self, values, name="Desk.swift"):
        source = self.source / name
        source.write_text("\n".join(json.dumps(key) for key in values))
        self.metadata(source, [{"key": key, "value": value} for key, value in values.items()], name + ".stringsdata")
        return source

    def metadata(self, source, entries, name):
        path = self.objects / name
        path.write_text(json.dumps({"source": str(source), "tables": {"Localizable": entries}, "version": 1}))
        return path

    def write_catalog(self, values):
        catalog = {"sourceLanguage": "en", "strings": {key: {
            "comment": "Keep metadata and formatting", "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": value}},
                "fr": {"stringUnit": {"state": "translated", "value": "Conserver"}}}}
            for key, value in values.items()}, "version": "1.0"}
        self.catalog.write_text(json.dumps(catalog, ensure_ascii=False, indent=4))

    def test_generated_accessors_cannot_replace_authored_words_or_formats(self):
        expected = {"workdesk.desk": "Your desk", "workdesk.material.count": "%lld materials",
                    "workdesk.brief.sendTo": "Send to %@"}
        self.authored(expected)
        self.metadata(self.root / "DerivedSources/GeneratedStringSymbols.swift", [
            {"key": "workdesk.desk"}, {"key": "workdesk.material.count", "value": "%lld"},
            {"key": "workdesk.brief.sendTo", "value": "%@"}], "GeneratedStringSymbols_Localizable.stringsdata")
        self.assertEqual(sync.collect_defaults(self.source, [self.objects]), expected)

    def test_dependencies_tests_and_other_checkouts_cannot_supply_app_copy(self):
        self.authored({"workdesk.desk": "Your desk"})
        for directory in ("Dependencies", "Tests", "AnotherCheckout"):
            source = self.root / directory / "Strings.swift"
            source.parent.mkdir()
            source.write_text('"workdesk.desk"')
            self.metadata(source, [{"key": "workdesk.desk", "value": "Wrong copy"}], directory + ".stringsdata")
        self.assertEqual(sync.collect_defaults(self.source, [self.objects]), {"workdesk.desk": "Your desk"})

    def test_missing_conflicting_and_placeholder_defaults_refuse_before_writing(self):
        source = self.authored({"workdesk.desk": "Your desk"})
        self.write_catalog({"workdesk.desk": "Original"})
        original = self.catalog.read_bytes()
        for value in (None, "%lld", "workdesk.desk", "Different text"):
            with self.subTest(value=value):
                self.metadata(source, [{"key": "workdesk.desk", "value": value}], "Conflict.stringsdata")
                with self.assertRaises(sync.CatalogError):
                    sync.synchronize(self.catalog, self.source, [self.objects], write=True)
                self.assertEqual(self.catalog.read_bytes(), original)

    def test_missing_metadata_refuses_instead_of_silently_keeping_incomplete_copy(self):
        self.authored({"workdesk.desk": "Your desk"})
        (self.source / "New.swift").write_text('"workdesk.new"')
        with self.assertRaisesRegex(sync.CatalogError, "workdesk.new"):
            sync.collect_defaults(self.source, [self.objects])

    def test_stale_compilation_refuses_before_writing(self):
        source = self.authored({"workdesk.desk": "Your desk"})
        self.write_catalog({"workdesk.desk": "Original"})
        original = self.catalog.read_bytes()
        stamp = source.stat().st_mtime_ns + 5_000_000_000
        os.utime(source, ns=(stamp, stamp))
        with self.assertRaisesRegex(sync.CatalogError, "Stale"):
            sync.synchronize(self.catalog, self.source, [self.objects], write=True)
        self.assertEqual(self.catalog.read_bytes(), original)

    def test_check_is_read_only_and_write_changes_only_english_value_spans(self):
        values = {"workdesk.desk": "Your desk", "workdesk.material.count": "%lld materials"}
        self.authored(values)
        self.write_catalog({"workdesk.desk": "Wrong", "workdesk.material.count": "%lld"})
        original = self.catalog.read_text()
        changed = sync.synchronize(self.catalog, self.source, [self.objects])
        self.assertEqual(set(changed), set(values))
        self.assertEqual(self.catalog.read_text(), original)
        sync.synchronize(self.catalog, self.source, [self.objects], write=True)
        self.assertEqual(self.catalog.read_text(), original.replace('"Wrong"', '"Your desk"').replace('"%lld"', '"%lld materials"'))
        self.assertEqual(sync.synchronize(self.catalog, self.source, [self.objects]), [])

    def test_new_key_is_added_without_reserializing_existing_translations(self):
        self.authored({"workdesk.new": "New project"})
        self.write_catalog({"unrelated": "Unchanged"})
        before = json.loads(self.catalog.read_text())
        sync.synchronize(self.catalog, self.source, [self.objects], write=True)
        after = json.loads(self.catalog.read_text())
        self.assertEqual(after["strings"]["unrelated"], before["strings"]["unrelated"])
        self.assertEqual(after["strings"]["workdesk.new"]["localizations"]["en"]["stringUnit"]["value"], "New project")

    def test_structured_translations_are_not_flattened(self):
        self.authored({"workdesk.count": "%lld materials"})
        self.catalog.write_text(json.dumps({"sourceLanguage": "en", "strings": {
            "workdesk.count": {"localizations": {"en": {"variations": {"plural": {}}}}}}}))
        original = self.catalog.read_bytes()
        with self.assertRaisesRegex(sync.CatalogError, "manual"):
            sync.synchronize(self.catalog, self.source, [self.objects], write=True)
        self.assertEqual(self.catalog.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
