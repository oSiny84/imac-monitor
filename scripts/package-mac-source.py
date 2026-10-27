"""Create a source-only Mac test ZIP, preserving Unix executable permissions.

Run on Windows with Python 3. No credentials, build output or downloaded tools
are included. Shell scripts are normalized to LF inside the archive only.
"""
from datetime import datetime
from pathlib import Path
import hashlib
import stat
import zipfile


def main():
    root = Path(__file__).resolve().parent.parent
    files = [root / name for name in (
        "Package.swift", "README.md", "IMPLEMENTATION_PLAN.md",
        "MAC_TEST_START_HERE.txt", "Build MacMonitor.command",
        "Uninstall MacMonitor.command",
        ".gitignore", ".gitattributes",
    )]
    allowed = {".swift", ".md", ".txt", ".plist", ".entitlements",
               ".xcprivacy", ".sh", ".py", ".go", ".mod", ".sum",
               ".html", ".js", ".css"}
    for folder in ("Sources", "Tests", "Resources", "scripts", "docs", "gateway"):
        files.extend(path for path in (root / folder).rglob("*")
                     if path.is_file() and not path.is_symlink()
                     and path.suffix in allowed
                     and not any(part.startswith(".") or part == "__pycache__"
                                 for part in path.relative_to(root).parts))
    output_dir = root / "releases"
    output_dir.mkdir(exist_ok=True)
    output = output_dir / f"MacMonitor-Mac-Test-{datetime.now():%Y%m%d-%H%M%S-%f}.zip"
    expected = {}
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(files):
            name = "MacMonitor/" + path.relative_to(root).as_posix()
            executable = path.suffix in (".sh", ".command")
            data = path.read_bytes()
            if executable:
                data = data.replace(b"\r\n", b"\n")
            info = zipfile.ZipInfo(name, datetime.now().timetuple()[:6])
            info.create_system = 3  # Unix: Finder restores executable bits.
            info.external_attr = (stat.S_IFREG | (0o755 if executable else 0o644)) << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(info, data)
            expected[name] = hashlib.sha256(data).digest()
    with zipfile.ZipFile(output) as archive:
        assert archive.testzip() is None
        assert set(archive.namelist()) == set(expected)
        for info in archive.infolist():
            assert hashlib.sha256(archive.read(info)).digest() == expected[info.filename]
            if info.filename.endswith((".command", ".sh")):
                assert info.create_system == 3
                assert (info.external_attr >> 16) & 0o777 == 0o755
                assert b"\r" not in archive.read(info)
    print(f"Verified {len(expected)} files, LF shell scripts, and executable permissions")
    print(f"ZIP: {output}")
    print(f"Bytes: {output.stat().st_size}")
    print(f"SHA256: {hashlib.sha256(output.read_bytes()).hexdigest()}")


if __name__ == "__main__":
    main()
