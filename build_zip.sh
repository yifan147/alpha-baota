#!/usr/bin/env bash
#
# 构建 btpanel_iqoo7.zip - 在当前目录从 base64 解码重建 ZIP 文件
#
# 用法:
#   bash build_zip.sh            # 生成本目录下 btpanel_iqoo7.zip
#   bash build_zip.sh /tmp/bt.zip # 指定输出路径
#
set -e

OUTPUT="${1:-$(dirname "$0")/btpanel_iqoo7.zip}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
B64_FILE="$SCRIPT_DIR/btpanel_iqoo7.zip.b64"

if [ ! -f "$B64_FILE" ]; then
  echo "[ERROR] 找不到 btpanel_iqoo7.zip.b64，请先从仓库克隆完整文件"
  exit 1
fi

if command -v base64 >/dev/null 2>&1; then
  # GNU base64
  base64 -d "$B64_FILE" > "$OUTPUT"
elif python3 -c "import base64; exit(0)" 2>/dev/null; then
  python3 -c "import base64,sys; open(sys.argv[2],'wb').write(base64.b64decode(open(sys.argv[1]).read()))" "$B64_FILE" "$OUTPUT"
else
  echo "[ERROR] 未找到 base64 或 python3，请安装任意一个后重试"
  exit 1
fi

if command -v unzip >/dev/null 2>&1; then
  unzip -tq "$OUTPUT" && echo "[OK] ZIP 文件校验通过: $OUTPUT"
else
  echo "[OK] ZIP 已生成: $OUTPUT (请刷入 Magisk)"
fi

echo ""
echo "使用方法:"
echo "  1. 打开 Magisk 管理器 → 模块 → 从本地安装"
echo "  2. 选择 $OUTPUT"
echo "  3. 重启设备，等待自动安装完成"
