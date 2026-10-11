#!/bin/zsh
# 开发者用：只打包指定 commit 的源码；不安装、不启动、不发送。
set -euo pipefail
cd "${0:A:h:h:h}"
python3 engineering/scripts/package-source.py "${1:-HEAD}"
