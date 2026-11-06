"""Build all three distributions on macOS with Go, npm, curl and ditto."""
import base64
import hashlib
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent
os.chdir(ROOT)
CACHE = ROOT / ".build"
DIST = ROOT / "dist"
VERSION = "2026.10.26"
BASE = f"https://github.com/yt-dlp/yt-dlp/releases/download/{VERSION}"

def run(*args, **kwargs):
    subprocess.run(args, check=True, **kwargs)

def fetch(name):
    path = CACHE / name
    if not path.exists():
        pending = path.with_suffix(path.suffix + ".tmp")
        run("curl", "-fLsS", "--retry", "2", f"{BASE}/{name}", "-o", str(pending))
        pending.replace(path)
    return path

def media(tool, platform, destination):
    package = f"@{tool}-installer/{platform}"
    version = {"ffmpeg": "4.1.0", "ffprobe": "5.1.0"}[tool]
    if platform == "darwin-arm64":
        version = {"ffmpeg": "4.1.5", "ffprobe": "5.0.1"}[tool]
    name = f"{tool}-installer-{platform}-{version}.tgz"
    archive = CACHE / name
    if not archive.exists():
        run("npm", "pack", f"{package}@{version}", "--pack-destination", str(CACHE))
    integrity = subprocess.check_output(
        ["npm", "view", f"{package}@{version}", "dist.integrity"], text=True
    ).strip()
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha512").digest()
    if "sha512-" + base64.b64encode(digest).decode() != integrity:
        raise ValueError(f"Invalid checksum for {archive.name}")
    with tarfile.open(archive) as source:
        with source.extractfile(f"package/{destination.name}") as binary:
            with destination.open("wb") as output:
                shutil.copyfileobj(binary, output)
        for member in source.getmembers():
            if Path(member.name).name.lower().startswith(("license", "readme")):
                with source.extractfile(member) as notice:
                    destination.with_name(f"{tool}-{Path(member.name).name}").write_bytes(notice.read())
    destination.chmod(0o755)

TARGETS = (
    ("windows", "amd64", "win32-x64", "Windows-x64"),
    ("darwin", "arm64", "darwin-arm64", "macOS-AppleSilicon"),
    ("darwin", "amd64", "darwin-x64", "macOS-Intel"),
)

def dependencies(platform, engine):
    CACHE.mkdir(exist_ok=True)
    sums = {line.split()[-1].lstrip("*"): line.split()[0] for line in fetch("SHA2-256SUMS").read_text().splitlines()}
    with fetch(engine).open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != sums[engine]:
            raise ValueError(f"Invalid checksum for {engine}")
    directory = CACHE / platform
    directory.mkdir(exist_ok=True)
    for tool in ("ffmpeg", "ffprobe"):
        media(tool, platform, directory / (tool + (".exe" if platform.startswith("win") else "")))

def build(selected):
    DIST.mkdir(exist_ok=True)
    go = os.environ.get("BILI_GO", "go")
    for system, arch, platform, suffix in TARGETS:
        if selected and suffix not in selected:
            continue
        engine_name = "yt-dlp.exe" if system == "windows" else "yt-dlp_macos"
        dependencies(platform, engine_name)
        folder = CACHE / f"BilibiliDownloader-{suffix}"
        if folder.exists():
            shutil.rmtree(folder)
        folder.mkdir()
        binary = folder / "BilibiliDownloader.exe"
        tools = folder / "tools"
        minimum = "11.0" if arch == "arm64" else "13.0"
        if system == "darwin":
            contents = folder / "Bilibili下载器.app" / "Contents"
            binary = contents / "MacOS" / "BilibiliEngine"
            binary.parent.mkdir(parents=True)
            tools = contents / "Resources" / "tools"
            (contents / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "BilibiliDownloader", "CFBundleIdentifier": "local.bilidownloader",
                "CFBundleName": "Bilibili下载器", "CFBundlePackageType": "APPL",
                "CFBundleVersion": "2.0", "CFBundleShortVersionString": "2.0.0",
                "LSMinimumSystemVersion": minimum,
            }))
        shutil.copytree(CACHE / platform, tools)
        exe = ".exe" if system == "windows" else ""
        engine = tools / f"yt-dlp{exe}"
        shutil.copy2(fetch(engine_name), engine)
        engine.chmod(0o755)
        shutil.copy2("yt-dlp-LICENSE", engine.parent / "yt-dlp-LICENSE")
        flags = "-s -w" + (" -H=windowsgui" if exe else "")
        run(go, "build", "-trimpath", "-ldflags", flags, "-o", str(binary), ".",
            env={**os.environ, "GOOS": system, "GOARCH": arch, "CGO_ENABLED": "0"})
        shutil.copy2("README.md", folder / ("README.md" if exe else "使用说明.md"))
        if system == "darwin":
            target = ("arm64" if arch == "arm64" else "x86_64") + f"-apple-macos{minimum}"
            run("xcrun", "swiftc", "-O", "-target", target, "macos.swift",
                "-o", str(binary.with_name("BilibiliDownloader")))
            run("codesign", "--force", "--sign", "-", str(binary))
            run("codesign", "--force", "--sign", "-", str(folder / "Bilibili下载器.app"))
        archive = DIST / f"{folder.name}.zip"
        archive.unlink(missing_ok=True)
        run("ditto", "-c", "-k", "--keepParent", str(folder), str(archive))

if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("targets", nargs="*", metavar="TARGET")
    args = parser.parse_args()
    if set(args.targets) - {target[-1] for target in TARGETS}:
        parser.error("TARGET must be Windows-x64, macOS-AppleSilicon or macOS-Intel")
    build(args.targets)
