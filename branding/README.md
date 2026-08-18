# branding/ — neutral placeholder art

`placeholders/` mirrors the Xcode asset-catalog paths (relative to `Conduck/`) and holds the
neutral art this repository ships in its catalogs — generic chat-bubble tiles and glyphs, no
brand marks. The official App Store build replaces these sets with proprietary Conduck brand
art at build time; that art is not part of this repository and is not covered by its license.

Regenerate (deterministic, safe to re-run): `python3 scripts/generate-placeholder-assets.py`
(requires Pillow). Output is byte-identical on every run and must match both `placeholders/`
and the asset catalogs.

What you may do with the Conduck name and the official brand art is settled by
[TRADEMARKS.md](../TRADEMARKS.md), not by this note — this file only covers how the
placeholder PNGs are made.
