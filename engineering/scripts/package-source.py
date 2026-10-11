#!/usr/bin/env python3
"""Commit-exact local source archive; preserve provenance without shipping signing or evidence."""
import io, re, subprocess, sys, zipfile
from pathlib import Path

def package(root, ref):
    def git(*args):
        return subprocess.run(["git", "-C", str(root), *args], check=True, capture_output=True).stdout
    commit = git("rev-parse", "--verify", ref + "^{commit}").decode().strip()
    version_result = subprocess.run(["git", "-C", str(root), "show", commit + ":Config/Version.xcconfig"], capture_output=True)
    if version_result.returncode == 0:
        version = re.search(r"^MARKETING_VERSION\s*=\s*([0-9]+\.[0-9]+\.[0-9]+)\s*$", version_result.stdout.decode(), re.MULTILINE).group(1)
    else:  # Historical source commits predate Version.xcconfig.
        generator = git("show", commit + ":scripts/generate-project.py").decode()
        version = re.search(r"MARKETING_VERSION='([0-9]+\.[0-9]+\.[0-9]+)'", generator).group(1)
    prefix = f"PadInk-{version}-{commit[:12]}/"
    files = git("ls-tree", "-rz", "--name-only", commit).decode().split("\0")
    def forbidden(name):
        p = Path(name)
        return name.startswith(("build/", ".build/", ".git/")) or (name.startswith("Config/") and name.endswith(".local.xcconfig")) or p.suffix.lower() in {".p12", ".pfx", ".p8", ".pem", ".cer", ".crt", ".der", ".key", ".mobileprovision", ".keychain", ".keychain-db"} or name == "SOURCE_COMMIT"
    bad = [name for name in files if name and forbidden(name)]
    if bad:
        raise ValueError("源码包包含本机配置、签名材料或构建数据，请先移出版本控制：" + ", ".join(bad))
    data = io.BytesIO(git("archive", "--format=zip", "--prefix=" + prefix, commit))
    with zipfile.ZipFile(data, "a", compression=zipfile.ZIP_DEFLATED) as z:
        z.writestr(prefix + "SOURCE_COMMIT", commit + "\n")
    out = root / "build/packages" / (prefix[:-1] + ".zip")
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(data.getvalue())
    return out

if __name__ == "__main__":
    try:
        out = package(Path(__file__).resolve().parents[2], sys.argv[1] if len(sys.argv) > 1 else "HEAD")
        with zipfile.ZipFile(out) as archive:
            guide = next((relative for relative in ["docs/开发者指南.md", "docs/开发者源码安装指南.md", "docs/使用者安装指南.md"] if any(name.endswith(relative) for name in archive.namelist())), "docs/使用者安装指南.md")
        print(f"已生成：{out}\n这是所选提交的开发者源码包，不含未提交 diff，也不是普通用户安装包。按包内 {guide} 操作；配对密钥、本机签名与验收文件不在包内。")
    except (subprocess.CalledProcessError, ValueError, AttributeError) as error:
        print("打包失败：" + str(error), file=sys.stderr); sys.exit(1)
