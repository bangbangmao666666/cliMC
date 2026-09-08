import hashlib
from pathlib import Path
import subprocess


ROOT = Path(__file__).parents[2]
PACKAGER = ROOT / "macos-voice/scripts/package-macos.sh"
ARCHIVE = ROOT / "dist/cliMC-macos-arm64.zip"
CHECKSUM = ROOT / "dist/cliMC-macos-arm64.zip.sha256"


def metadata(path: Path):
    if not path.exists():
        return None
    stat = path.stat()
    digest = hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None
    return stat.st_mtime_ns, stat.st_size, digest


def test_packager_creates_verified_archive_without_touching_installation(tmp_path):
    assert PACKAGER.is_file(), "packaging script must exist"
    protected = [
        Path.home() / "Applications/cliMC.app/Contents/MacOS/codex-voice-hotkey",
        Path.home() / ".local/bin/codex-voice-hotkey",
        Path.home() / "Library/LaunchAgents/com.codex.voice-hotkey.plist",
    ]
    before = {path: metadata(path) for path in protected}

    result = subprocess.run([str(PACKAGER)], cwd=ROOT, text=True, capture_output=True)

    assert result.returncode == 0, result.stdout + result.stderr
    assert ARCHIVE.is_file()
    assert CHECKSUM.is_file()
    checksum_result = subprocess.run(
        ["shasum", "-a", "256", "-c", CHECKSUM.name],
        cwd=CHECKSUM.parent,
        text=True,
        capture_output=True,
    )
    assert checksum_result.returncode == 0, checksum_result.stdout + checksum_result.stderr

    subprocess.run(["ditto", "-x", "-k", str(ARCHIVE), str(tmp_path)], check=True)
    app = tmp_path / "cliMC.app"
    executable = app / "Contents/MacOS/codex-voice-hotkey"
    architecture = subprocess.run(
        ["file", str(executable)], check=True, text=True, capture_output=True
    ).stdout
    assert "arm64" in architecture
    assert "x86_64" not in architecture
    bundle_id = subprocess.run(
        [
            "plutil",
            "-extract",
            "CFBundleIdentifier",
            "raw",
            str(app / "Contents/Info.plist"),
        ],
        check=True,
        text=True,
        capture_output=True,
    ).stdout.strip()
    assert bundle_id == "local.climc.app"
    subprocess.run(
        ["codesign", "--verify", "--deep", "--strict", str(app)], check=True
    )
    assert {path: metadata(path) for path in protected} == before
