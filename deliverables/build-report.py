#!/usr/bin/env python3
"""Render Audit/finding-F1-legacy-emergency-unpause-brick.md to a printable HTML report.

Usage:  python3 deliverables/build-report.py                 # F1 report
        python3 deliverables/build-report.py <report.md>       # any report
Then:   open the html and print to PDF (A4).
"""
from __future__ import annotations

import pathlib
import sys

try:
    import markdown  # type: ignore
except ImportError:  # pragma: no cover
    sys.exit("pip install --break-system-packages markdown")

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else (
    ROOT / "Audit" / "finding-F1-legacy-emergency-unpause-brick.md")
OUT = ROOT / "deliverables" / (SRC.stem + ".html")

CSS = """
@page { size: A4; margin: 18mm 15mm; }
:root { --ink:#111; --mut:#555; --line:#d7dbe0; --accent:#0b5fff; --warn:#b00020; }
* { box-sizing: border-box; }
body { font: 11pt/1.5 -apple-system, "Segoe UI", Inter, Helvetica, Arial, sans-serif;
       color: var(--ink); max-width: 900px; margin: 0 auto; padding: 28px 22px 60px; }
h1 { font-size: 21pt; line-height: 1.2; margin: 0 0 4px; letter-spacing: -0.01em; }
h2 { font-size: 13.5pt; margin: 30px 0 10px; padding-bottom: 5px; border-bottom: 1px solid var(--line); }
h3 { font-size: 11.5pt; margin: 20px 0 6px; }
p, li { margin: 7px 0; }
ul, ol { padding-left: 22px; }
code { font: 9.5pt/1.45 "SFMono-Regular", ui-monospace, Menlo, Consolas, monospace;
       background: #f4f6f8; padding: 1px 4px; border-radius: 3px; }
pre { background: #f7f8fa; border: 1px solid var(--line); border-left: 3px solid var(--accent);
      border-radius: 4px; padding: 11px 13px; overflow-x: auto; page-break-inside: avoid; }
pre code { background: none; padding: 0; font-size: 9pt; }
table { border-collapse: collapse; width: 100%; margin: 12px 0; font-size: 9.8pt;
        page-break-inside: avoid; }
th, td { border: 1px solid var(--line); padding: 6px 9px; text-align: left; vertical-align: top; }
th { background: #f2f4f7; font-weight: 600; }
blockquote { margin: 12px 0; padding: 8px 14px; border-left: 3px solid #ffb300;
             background: #fffdf3; color: #3a3a3a; }
hr { border: 0; border-top: 1px solid var(--line); margin: 26px 0; }
.cover { border: 1px solid var(--line); border-radius: 6px; padding: 18px 20px; margin: 0 0 26px;
         background: #fbfcfd; }
.cover .kicker { font-size: 9pt; letter-spacing: .12em; text-transform: uppercase; color: var(--mut); }
.cover .sub { color: var(--mut); font-size: 10pt; margin-top: 8px; }
.cover .badge { display: inline-block; margin-top: 12px; padding: 4px 10px; border-radius: 999px;
                background: #fff1f2; color: var(--warn); border: 1px solid #ffd0d6;
                font-size: 9pt; font-weight: 600; }
.footer { margin-top: 40px; padding-top: 12px; border-top: 1px solid var(--line);
          color: var(--mut); font-size: 8.8pt; }
@media print { a { color: inherit; text-decoration: none; } }
"""

TEMPLATE = """<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>{css}</style></head>
<body>
<div class="cover">
  <div class="kicker">Security assessment &middot; Cetus CLMM (Sui Move) &middot; source snapshot b7c3a5a</div>
  <h1>{title}</h1>
  <div class="sub">Target: <code>cetus_clmm::config</code> &middot; deployed v14 (active) and v15 &middot;
  PoC: <code>packages/cetus_clmm/tests/emergency_unpause_legacy_bypass_tests.move</code> &middot;
  scripts: <code>exploits/</code></div>
  <div class="badge">Unrecoverable protocol-wide freeze &middot; requires ACL bit 5</div>
</div>
{body}
<div class="footer">Generated from <code>Audit/finding-F1-legacy-emergency-unpause-brick.md</code>.
Print this page to PDF (A4) for a signed submission. Line references are to the vendored
<code>packages/cetus_clmm/sources</code> tree at commit <code>b7c3a5a</code>; v14 references are to
upstream branch <code>version-14</code>.</div>
</body></html>
"""


def main() -> None:
    text = SRC.read_text()
    lines = text.splitlines()
    if lines and lines[0].startswith("# "):
        title, body_md = lines[0][2:].strip(), "\n".join(lines[1:])
    else:
        title, body_md = "Cetus CLMM — audit finding", text

    body = markdown.markdown(
        body_md,
        extensions=["tables", "fenced_code", "sane_lists", "attr_list"],
        output_format="html5",
    )
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(TEMPLATE.format(title=title, css=CSS, body=body))
    print(f"wrote {OUT.relative_to(ROOT)}  ({OUT.stat().st_size} bytes, "
          f"{body.count('<table>')} tables, {body.count('<pre>')} code blocks)")


if __name__ == "__main__":
    main()
