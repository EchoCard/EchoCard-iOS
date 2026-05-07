#!/bin/bash

# 截图生成脚本
# 用于生成App Store所需的截图尺寸
# 支持处理 screenshot 文件夹下的多个源文件

set -e

# 颜色输出
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}📸 开始批量生成 App Store 截图...${NC}"

# 源截图文件夹
SOURCE_DIR="./screenshot"
# 输出目录
OUTPUT_DIR="./Screenshots_Output"

# 检查源目录是否存在
if [ ! -d "$SOURCE_DIR" ]; then
    echo -e "${RED}❌ 错误: 找不到源文件夹 $SOURCE_DIR${NC}"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# 去掉 PNG 的 alpha 通道（App Store 截图等场景常要求无透明）
strip_alpha_png() {
    local f="$1"
    local tmp="${TMPDIR:-/tmp}/genshot_alpha_$$.png"
    if command -v ffmpeg >/dev/null 2>&1; then
        if ffmpeg -y -hide_banner -loglevel error -i "$f" -vf "format=rgb24" -frames:v 1 "$tmp" && mv "$tmp" "$f"; then
            return 0
        fi
        rm -f "$tmp"
    fi
    # 回退：经 JPEG 再转 PNG（会略有损；请安装 ffmpeg 以获得无 alpha 的 PNG 且更少重压缩）
    local j="${TMPDIR:-/tmp}/genshot_jpg_$$.jpg"
    if sips -s format jpeg "$f" --out "$j" >/dev/null 2>&1 && sips -s format png "$j" --out "$f" >/dev/null 2>&1; then
        rm -f "$j"
        return 0
    fi
    rm -f "$j" "$tmp"
    echo -e "${RED}  ⚠ 无法去掉 alpha：请安装 ffmpeg（brew install ffmpeg）或检查 sips${NC}" >&2
    return 1
}

declare -a SIZES=(
    "1242x2688"
)

# 获取所有 PNG 文件（扩展名大小写不敏感：.png / .PNG / .PnG 等）
shopt -s nullglob nocaseglob
FILES=("$SOURCE_DIR"/*.png)
shopt -u nullglob nocaseglob

if [ ${#FILES[@]} -eq 0 ]; then
    echo -e "${RED}❌ 错误: $SOURCE_DIR 文件夹内没有 PNG 文件（.png / .PNG 均可）${NC}"
    exit 1
fi

echo -e "${YELLOW}📂 源目录: $SOURCE_DIR${NC}"
echo -e "${YELLOW}📂 输出目录: $OUTPUT_DIR${NC}"
echo ""

# 遍历每个文件
for source_file in "${FILES[@]}"; do
    base=$(basename "$source_file")
    filename="${base%.*}"
    echo -e "${GREEN}📄 处理文件: $filename${NC}"
    
    # 为每个文件生成 4 种尺寸
    for size in "${SIZES[@]}"; do
        width=$(echo $size | cut -d'x' -f1)
        height=$(echo $size | cut -d'x' -f2)
        
        # 构造输出文件名: 原文件名_尺寸.png
        output_file="$OUTPUT_DIR/${filename}_${size}.png"
        
        # 使用 sips 强制调整到目标尺寸
        # 注意: sips -z height width (高度在前)
        sips -z "$height" "$width" "$source_file" --out "$output_file" > /dev/null 2>&1
        strip_alpha_png "$output_file" || true
        
        echo -e "  ✅ 已生成: ${size}"
    done
    echo ""
done

echo -e "${GREEN}✨ 批量生成完成！${NC}"
echo -e "${YELLOW}📁 请在 $OUTPUT_DIR 文件夹中查看结果。${NC}"
