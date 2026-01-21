#!/bin/bash
# 从临时文件恢复翻译结果

set -e

echo "=== 翻译恢复工具 ==="
echo

# 查找最新的临时文件
LATEST_TEMP=$(ls -t /tmp/git-translate-new-* 2>/dev/null | head -1)

if [ -z "$LATEST_TEMP" ]; then
    echo "❌ 没有找到临时文件"
    echo "   翻译可能还没有开始"
    exit 1
fi

echo "找到临时文件: $LATEST_TEMP"
echo "文件大小: $(ls -lh $LATEST_TEMP | awk '{print $5}')"
echo "修改时间: $(ls -l $LATEST_TEMP | awk '{print $6, $7, $8}')"
echo

# 显示文件前几行
echo "文件内容预览:"
echo "---"
head -20 "$LATEST_TEMP"
echo "---"
echo

# 询问用户
echo "请选择目标文件:"
echo "1) CLOUDFLARE_DEPLOYMENT.md"
echo "2) README.md"
echo "3) 手动输入文件名"
echo
read -p "请输入选择 (1-3): " CHOICE

case $CHOICE in
    1)
        TARGET="CLOUDFLARE_DEPLOYMENT.md"
        ;;
    2)
        TARGET="README.md"
        ;;
    3)
        read -p "请输入目标文件名: " TARGET
        ;;
    *)
        echo "❌ 无效选择"
        exit 1
        ;;
esac

echo
echo "目标文件: $TARGET"
echo

# 备份原文件
if [ -f "$TARGET" ]; then
    BACKUP="${TARGET}.backup.$(date +%Y%m%d-%H%M%S)"
    cp "$TARGET" "$BACKUP"
    echo "✓ 已备份原文件到: $BACKUP"
fi

# 复制翻译结果
cp "$LATEST_TEMP" "$TARGET"
echo "✓ 已恢复翻译结果到: $TARGET"

# 清理临时文件
read -p "是否删除临时文件? (y/N): " CLEANUP
if [ "$CLEANUP" = "y" ] || [ "$CLEANUP" = "Y" ]; then
    rm "$LATEST_TEMP"
    echo "✓ 已删除临时文件"
fi

echo
echo "=== 恢复完成 ==="
