#!/usr/bin/env python3
"""Package the mod folder into dist/mod_bb_coop.zip for Battle Brothers' data folder."""
import pathlib
import zipfile

root = pathlib.Path(__file__).resolve().parent
src = root / "mod"
out = root / "dist" / "mod_bb_coop.zip"
out.parent.mkdir(exist_ok=True)
with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
    for f in sorted(src.rglob("*")):
        if f.is_file():
            z.write(f, f.relative_to(src).as_posix())
print(f"Wrote {out}")
