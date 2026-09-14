"""Build a release from an explicit allowlist; never package local settings."""

import argparse
from pathlib import Path
import re
from zipfile import ZIP_DEFLATED, ZipFile


ROOT = Path(__file__).resolve().parents[1]
PLUGIN = "audiobookshelfbridge.koplugin"
FILES = (
    "main.lua",
    "_meta.lua",
    "audiobookshelfbridge_version.lua",
    "audiobookshelfbridge_config.example.lua",
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    "audiobookshelfbridge/api.lua",
    "audiobookshelfbridge/bookdetailswidget.lua",
    "audiobookshelfbridge/browser.lua",
    "audiobookshelfbridge/covercache.lua",
    "audiobookshelfbridge/covergrid.lua",
    "audiobookshelfbridge/downloadstaging.lua",
    "audiobookshelfbridge/ebookfilewidget.lua",
    "audiobookshelfbridge/errorlog.lua",
    "audiobookshelfbridge/metadatawriter.lua",
    "audiobookshelfbridge/settings.lua",
    "audiobookshelfbridge/settingsmenu.lua",
    "audiobookshelfbridge/titlebar.lua",
)


def version():
    text = (ROOT / "audiobookshelfbridge_version.lua").read_text()
    match = re.fullmatch(
        r"\s*return\s*\{\s*(0|[1-9][0-9]*)\s*,\s*(0|[1-9][0-9]*)\s*,\s*(0|[1-9][0-9]*)\s*\}\s*",
        text,
    )
    if not match:
        raise ValueError("Expected version file containing return { major, minor, patch }")
    return ".".join(match.groups())


def build():
    release_version = version()
    # Check the full manifest and plugin imports before creating any archive.
    for name in FILES:
        source = ROOT / name
        if source.is_symlink() or not source.is_file():
            raise ValueError(f"Missing or symlinked release file: {name}")
        if source.suffix == ".lua":
            for module in re.findall(r'require\("(audiobookshelfbridge[^" ]*)"\)', source.read_text()):
                if module + ".lua" not in FILES:
                    raise ValueError(f"{name} imports unpackaged module: {module}")
    output = ROOT / "dist" / f"{PLUGIN}.zip"
    output.parent.mkdir(exist_ok=True)
    with ZipFile(output, "w", compression=ZIP_DEFLATED) as archive:
        for name in FILES:
            archive.write(ROOT / name, f"{PLUGIN}/{name}")
    print(f"Built {output} (v{release_version}, {len(FILES)} files)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", action="store_true", help="Print the version without building")
    args = parser.parse_args()
    if args.version:
        print(version())
    else:
        build()
