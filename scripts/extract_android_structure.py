#!/usr/bin/env python3
"""Index the full Android client, without copying credentials or build outputs.

This is a lexical source index, not a Kotlin parser or proof of runtime coverage.
The manually traced product structure lives in docs/ANDROID_STRUCTURE.md.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import subprocess
import xml.etree.ElementTree as ET


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def extract(root):
    scope = ["app/src/main", "app/build.gradle.kts", "build.gradle.kts", "settings.gradle.kts"]
    if git(root, "status", "--porcelain", "--", *scope):
        raise SystemExit("Android input has uncommitted changes; commit or select a clean checkout first")
    paths = sorted(git(root, "ls-files", "--", *scope).splitlines())
    digest = hashlib.sha256()
    files = []
    extension_counts = Counter()
    for path in paths:
        content = (root / path).read_bytes()
        sha = hashlib.sha256(content).hexdigest()
        digest.update(f"{path}\0{sha}\n".encode())
        extension_counts[Path(path).suffix] += 1
        if not path.endswith(".kt"):
            continue
        lines = content.decode().splitlines()
        declarations = []
        surfaces = []
        for number, line in enumerate(lines, 1):
            declaration = re.match(
                r"\s*(?:(?:private|internal|public|suspend|data|sealed|enum|abstract|open|override|inline|tailrec|const)\s+)*"
                r"(fun|class|object|interface)\s+(?:<[^>]+>\s+)?([\w.]+)", line)
            if declaration:
                declarations.append({"kind": declaration[1], "name": declaration[2], "line": number})
            for surface in re.finditer(r"\b(AlertDialog|ModalBottomSheet|Dialog|DropdownMenu|CodeGateDialog|CodeSetupDialog)\s*\(", line):
                if not line.lstrip().startswith("//"):
                    surfaces.append({"call": surface[1], "line": number})
        files.append({"path": path, "sha256": sha, "lines": len(lines),
                      "declarations": declarations, "surface_calls": surfaces})
    manifest = ET.parse(root / "app/src/main/AndroidManifest.xml").getroot()
    android = "{http://schemas.android.com/apk/res/android}"
    components = []
    for element in manifest.find("application"):
        if element.tag in {"activity", "service", "receiver", "provider"}:
            components.append({"type": element.tag, "name": element.get(android + "name"),
                               "exported": element.get(android + "exported"),
                               "actions": sorted({x.get(android + "name") for x in element.findall("intent-filter/action")}),
                               "links": [{k.removeprefix(android): v for k, v in x.attrib.items()}
                                         for x in element.findall("intent-filter/data")]})
    return {"schema": 1, "android_commit": git(root, "rev-parse", "HEAD"),
            "scope": scope, "tracked_file_count": len(paths), "source_tree_sha256": digest.hexdigest(),
            "extension_counts": dict(sorted(extension_counts.items())),
            "kotlin_file_count": len(files), "kotlin_line_count": sum(x["lines"] for x in files),
            "resource_value_directories": sorted(p.name for p in (root / "app/src/main/res").glob("values*")),
            "manifest_components": components, "kotlin_files": files}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("android_root", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "docs/ANDROID_SOURCE_INDEX.json")
    parser.add_argument("--check", action="store_true", help="Compare to the saved snapshot without writing")
    args = parser.parse_args()
    result = extract(args.android_root.resolve())
    rendered = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if args.check:
        if args.output.read_text() != rendered:
            raise SystemExit("Android source differs from the recorded structure snapshot")
        print(f"PASS: {result['kotlin_file_count']} Kotlin files, {result['kotlin_line_count']} lines; manifest and source digest match")
    else:
        args.output.write_text(rendered)
        print(f"Wrote {args.output}: {result['kotlin_file_count']} Kotlin files")


if __name__ == "__main__":
    main()
