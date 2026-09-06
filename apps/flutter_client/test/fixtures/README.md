# ReadArc regression fixtures

This directory contains deterministic document fixtures used by automated reader tests.

Canonical Sprint 48 fixtures:

- `txt_characterization.txt` — paragraphs and character-based locator restore.
- `fb2_characterization.fb2` — title and paragraph structure.
- `epub_characterization.epub` — spine content, internal `path#fragment` links and anchors.
- `pdf_characterization.pdf` — valid two-page, text-bearing PDF for extraction and page locators.
- `docx_characterization.docx` — heading, paragraphs, a table and an explicit page break.
- `djvu_characterization.djvu` — deterministic two-page bundled-container probe fixture.

The `epub_source/` and `docx_source/` directories are the readable canonical sources used to
rebuild the binary ZIP fixtures. Their timestamps and ZIP metadata are normalized when the
fixtures are regenerated.

Rules:

1. Fixtures must be small and redistributable in the repository.
2. Tests assert semantic structure, extracted text, pages/blocks, anchors and locator restore;
   source-string checks are not accepted as reader behavior coverage.
3. A fixture that reproduces a production regression must never be silently replaced with an easier file.
4. Large/private user books are not committed. A reduced synthetic fixture should be produced from the failing structure.
