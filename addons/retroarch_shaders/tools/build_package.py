"""Build or verify a Godot Asset Store add-on or standalone demo project.

Builds use a private staging directory and never replace an existing release.
The manifest covers every distributed file except itself. ZIP metadata is fixed
so identical source bytes produce identical archives on the same Python/zlib.
"""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import tempfile
import zipfile


ADDON = Path(__file__).resolve().parents[1]
ADDON_PREFIX = "addons/retroarch_shaders"
MANIFEST = "manifest.json"
ADDON_MANIFEST = f"{ADDON_PREFIX}/{MANIFEST}"
FORMATS = ("standalone", "addon")
MAX_STORE_BYTES = 1_000_000_000
IGNORED_NAMES = {
    ".git", ".godot", ".mypy_cache", ".pytest_cache", ".ruff_cache",
    "__pycache__", "build", "dist", "test-results", ".DS_Store", "Thumbs.db",
}
IGNORED_SUFFIXES = {".pyc", ".pyo", ".import", ".tmp", ".bak"}
REQUIRED_FILES = ("README.md", "LICENSE", "VERSION", "demo/demo.gd", "demo/demo.tscn")
PROJECT = '''config_version=5

[application]
config/name="Libretro Shaders for Godot"
config/version="{version}"
run/main_scene="res://addons/retroarch_shaders/demo/demo.tscn"
config/features=PackedStringArray("4.7", "GL Compatibility")

[display]
window/size/viewport_width=960
window/size/viewport_height=720

[rendering]
renderer/rendering_method="gl_compatibility"
renderer/rendering_method.mobile="gl_compatibility"

[debug]
file_logging/enable_file_logging=false
'''
README = '''# Libretro Shaders for Godot

Open `project.godot` with Godot 4.7.1 using the Compatibility renderer,
then run the project to try the synthetic demo. No game assets are required.
Other engine versions have not been verified.

To install in another Godot project, copy `addons/retroarch_shaders` into its
`addons` directory. See the [add-on documentation](addons/retroarch_shaders/README.md)
for setup, API usage, shader compatibility, licensing and development checks.

Before opening the project, verify this distribution with Python 3.10 or newer:

```sh
python addons/retroarch_shaders/tools/build_package.py --verify .
```

Verification checks the exact file inventory and SHA-256 hashes in `manifest.json`.
It detects accidental changes; it is not a signature proving publisher identity.
The [MIT license](LICENSE) covers this add-on, not external shaders or their assets.
'''


def package_files(root, *, exclude_generated=False):
    """List regular files without following symlinks or Windows junctions."""
    files = []
    for path in sorted(root.iterdir(), key=lambda entry: entry.name):
        if exclude_generated and (path.name in IGNORED_NAMES or path.suffix in IGNORED_SUFFIXES):
            continue
        # st_file_attributes also catches junctions on Python 3.10/3.11, which
        # predate Path.is_junction(). Other reparse points stay out as well.
        attributes = getattr(path.lstat(), "st_file_attributes", 0)
        if attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT or path.is_symlink():
            raise ValueError(f"Links are not permitted in a package: {path}")
        if path.is_dir():
            files.extend(package_files(path, exclude_generated=exclude_generated))
        elif path.is_file():
            files.append(path)
        else:
            raise ValueError(f"Not a regular package file: {path}")
    return files


def sha256_file(path):
    """Hash large files without retaining their contents in memory."""
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_member(name):
    """Require portable relative names before comparing package inventories."""
    if not isinstance(name, str) or not name or "\\" in name or ":" in name:
        raise ValueError(f"Invalid package path: {name!r}")
    if PurePosixPath(name).is_absolute() or any(part in ("", ".", "..") for part in name.split("/")):
        raise ValueError(f"Invalid package path: {name!r}")


def validate_manifest(raw, names, manifest_name=MANIFEST):
    """Check manifest structure, portable paths and exact inventory membership."""
    def unique_entries(entries):
        result = {}
        for key, value in entries:
            if key in result:
                raise ValueError(f"Duplicate manifest entry: {key}")
            result[key] = value
        return result

    manifest = json.loads(raw, object_pairs_hook=unique_entries)
    if not isinstance(manifest, dict) or not manifest:
        raise ValueError("Manifest must be a nonempty mapping of paths to SHA-256 hashes.")
    for name, digest in manifest.items():
        validate_member(name)
        if name == manifest_name or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError(f"Invalid manifest entry: {name}")
    folded = set()
    for name in names:
        validate_member(name)
        if name.casefold() in folded:
            raise ValueError(f"Duplicate or case-colliding package path: {name}")
        folded.add(name.casefold())
    expected = set(manifest) | {manifest_name}
    actual = set(names)
    if actual != expected:
        missing = ", ".join(sorted(expected - actual)) or "none"
        extra = ", ".join(sorted(actual - expected)) or "none"
        raise ValueError(f"Package inventory differs from manifest (missing: {missing}; extra: {extra}).")
    return manifest


def find_manifest(names):
    """Recognize the two layouts and keep add-on archives inside their namespace."""
    if MANIFEST in names:
        return MANIFEST
    if ADDON_MANIFEST not in names:
        raise ValueError("Package manifest is missing.")
    if any(not name.startswith(ADDON_PREFIX + "/") for name in names):
        raise ValueError(f"Add-on packages may only contain files inside {ADDON_PREFIX}/.")
    return ADDON_MANIFEST


def verify_package(path):
    """Verify an untouched package directory or ZIP; return its file count."""
    path = Path(path)
    if path.is_dir():
        files = package_files(path)
        names = [item.relative_to(path).as_posix() for item in files]
        manifest_name = find_manifest(names)
        manifest = validate_manifest((path / manifest_name).read_bytes(), names, manifest_name)
        for name, digest in manifest.items():
            if sha256_file(path / name) != digest:
                raise ValueError(f"SHA-256 mismatch: {name}")
    else:
        with zipfile.ZipFile(path) as bundle:
            entries = bundle.infolist()
            for entry in entries:
                kind = stat.S_IFMT(entry.external_attr >> 16)
                if entry.is_dir() or kind not in (0, stat.S_IFREG):
                    raise ValueError(f"Not a regular package file: {entry.filename}")
            names = [entry.filename for entry in entries]
            manifest_name = find_manifest(names)
            manifest = validate_manifest(bundle.read(manifest_name), names, manifest_name)
            for name, digest in manifest.items():
                if hashlib.sha256(bundle.read(name)).hexdigest() != digest:
                    raise ValueError(f"SHA-256 mismatch: {name}")
    return len(manifest) + 1


def write_archive(project, archive):
    """Fix file order, timestamps, permissions and compression for repeatability."""
    with zipfile.ZipFile(archive, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as bundle:
        for path in package_files(project):
            info = zipfile.ZipInfo(path.relative_to(project).as_posix(), date_time=(2026, 1, 1, 0, 0, 0))
            info.create_system = 3
            info.external_attr = 0o100644 << 16
            bundle.writestr(info, path.read_bytes(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def publish_package(project, staged_archive, output, archive):
    """Reserve both outputs exclusively and roll back only files we created."""
    owns_output = False
    owns_archive = False
    try:
        output.mkdir()
        owns_output = True
        with archive.open("xb") as destination:
            owns_archive = True
            with staged_archive.open("rb") as source:
                shutil.copyfileobj(source, destination)
        # Moving a TemporaryDirectory child retains its restrictive Windows ACL.
        # Fresh directories and byte copies inherit the release parent's access
        # rules, allowing Godot and subsequent verification processes to read it.
        for source in package_files(project):
            destination = output / source.relative_to(project)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
    except BaseException:
        if owns_archive:
            archive.unlink()
        if owns_output:
            shutil.rmtree(output)
        raise


def read_version(source):
    """Require a release version and keep repository/add-on metadata in sync."""
    source = Path(source)
    version = (source / "VERSION").read_text(encoding="utf-8").strip()
    number = r"(?:0|[1-9][0-9]*)"
    prerelease = rf"(?:{number}|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
    pattern = rf"{number}\.{number}\.{number}(?:-{prerelease}(?:\.{prerelease})*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    if not re.fullmatch(pattern, version):
        raise ValueError("Add-on VERSION must contain a semantic release version, for example 1.0.0.")
    root_version = source.parent.parent / "VERSION"
    if source.parent.name == "addons" and root_version.is_file():
        if root_version.read_text(encoding="utf-8").strip() != version:
            raise ValueError("Root and add-on VERSION files differ.")
    return version


def default_output(package_format):
    suffix = "-demo" if package_format == "standalone" else ""
    return ADDON.parents[1] / "build" / f"godot-libretro-shaders-{read_version(ADDON)}{suffix}"


def validate_output_location(output, source):
    """Keep generated projects out of a host's source/import directories."""
    if output == source or source in output.parents:
        raise ValueError("Output must stay outside the source add-on.")
    if source.parent.name == "addons":
        host = source.parent.parent
        if (output == host or host in output.parents) and (host / "build") not in output.parents:
            raise ValueError("Outputs inside the host project must be in a subdirectory of build/.")


def build_package(output, source=ADDON, *, package_format="standalone", reuse_identical=False):
    """Build a package and sibling ZIP; existing artifacts are never overwritten."""
    if package_format not in FORMATS:
        raise ValueError(f"Unknown package format: {package_format}")
    output = Path(output)
    if output.is_symlink() or (output.exists() and
            getattr(output.lstat(), "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT):
        raise ValueError("The output directory is a link; choose a fresh output path.")
    output = output.resolve()
    source = Path(source).resolve()
    archive = output.with_name(output.name + ".zip")
    validate_output_location(output, source)
    existing = output.exists() or archive.exists() or output.is_symlink() or archive.is_symlink()
    if existing and not reuse_identical:
        raise ValueError("The output directory or ZIP already exists; choose a fresh output path.")
    for name in REQUIRED_FILES:
        if not (source / name).is_file():
            raise ValueError(f"Required add-on file is missing: {name}")
    version = read_version(source)
    files = [path for path in package_files(source, exclude_generated=True)
             if path != source / MANIFEST]
    output.parent.mkdir(parents=True, exist_ok=True)
    # Build outputs under the host project must not get imported as duplicate
    # add-on scripts/resources. Never put .gdignore in an arbitrary parent.
    build_root = source.parent.parent / "build"
    if source.parent.name == "addons" and build_root in output.parents:
        ignore_file = build_root / ".gdignore"
        if not ignore_file.exists():
            ignore_file.touch()
    with tempfile.TemporaryDirectory(prefix=".retroarch-package-", dir=output.parent) as temporary:
        staging = Path(temporary)
        project = staging / "project"
        addon = project / ADDON_PREFIX
        for path in files:
            destination = addon / path.relative_to(source)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, destination)
        if package_format == "standalone":
            for name in ("LICENSE", "VERSION"):
                shutil.copyfile(addon / name, project / name)
            generated = {
                "README.md": README,
                "project.godot": PROJECT.format(version=version),
                ".gitignore": ".godot/\n__pycache__/\n*.pyc\n/test-results/\n/build/\n/dist/\n",
                ".gitattributes": "* text=auto eol=lf\n",
            }
            for name, contents in generated.items():
                (project / name).write_text(contents, encoding="utf-8", newline="\n")
        manifest = {path.relative_to(project).as_posix(): sha256_file(path) for path in package_files(project)}
        manifest_name = MANIFEST if package_format == "standalone" else ADDON_MANIFEST
        (project / manifest_name).write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                                            encoding="utf-8", newline="\n")
        count = verify_package(project)
        staged_archive = staging / "package.zip"
        write_archive(project, staged_archive)
        if package_format == "addon" and staged_archive.stat().st_size > MAX_STORE_BYTES:
            raise ValueError("Asset Store ZIP exceeds the 1 GB per-version size limit.")
        verify_package(staged_archive)
        if existing:
            if (not output.is_dir() or not archive.is_file() or archive.is_symlink()
                    or getattr(archive.lstat(), "st_file_attributes", 0) & stat.FILE_ATTRIBUTE_REPARSE_POINT):
                raise ValueError("Existing output is incomplete or linked; choose a fresh output path.")
            if (verify_package(output) != count or verify_package(archive) != count
                    or sha256_file(output / manifest_name) != sha256_file(project / manifest_name)
                    or sha256_file(archive) != sha256_file(staged_archive)):
                raise ValueError("Existing release differs from this build; choose a fresh output path.")
        else:
            publish_package(project, staged_archive, output, archive)
    return output, archive, count


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group()
    action.add_argument("--output-dir", type=Path,
                        help="Package directory and sibling ZIP; use build/<name> inside a host project (default: versioned build/ path)")
    action.add_argument("--verify", type=Path, metavar="PACKAGE", help="Verify a pristine package directory or ZIP")
    parser.add_argument("--format", choices=FORMATS, default="standalone", dest="package_format",
                        help="addon: Asset Store ZIP; standalone: runnable demo project (default)")
    parser.add_argument("--reuse-identical", action="store_true",
                        help="Succeed if both existing artifacts exactly match this build; never overwrite changes")
    args = parser.parse_args(argv)
    try:
        if args.verify is not None:
            count = verify_package(args.verify)
            print(f"Verified: {args.verify}\nFiles: {count}")
        else:
            output, archive, count = build_package(args.output_dir or default_output(args.package_format),
                                                   package_format=args.package_format,
                                                   reuse_identical=args.reuse_identical)
            print(f"Format: {args.package_format}\nPackage: {output}\nArchive: {archive}\nFiles: {count}")
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        parser.exit(1, f"Package error: {error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
