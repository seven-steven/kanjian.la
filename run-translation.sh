#!/bin/bash
# 翻译执行脚本 - 使用更长的超时时间和后台运行

set -e

echo "=== 开始翻译任务 ==="
echo "开始时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo

# 设置超时时间为 15 分钟
TIMEOUT=900

echo "超时设置: ${TIMEOUT} 秒 ($((${TIMEOUT}/60)) 分钟)"
echo "建议: 使用 ./monitor-translation.sh 在另一个终端监控进度"
echo

# 执行翻译（如果超时会被终止）
timeout $TIMEOUT ../git-translate update 2>&1 | tee translation-$(date +%Y%m%d-%H%M%S).log

EXIT_CODE=${?}

echo
echo "=== 翻译任务结束 ==="
echo "结束时间: $(date '+%Y-%m-%d %H:%M:%S')"

if [ $EXIT_CODE -eq 143 ]; then
    echo
    echo "⚠️ 翻译超时"
    echo "原因: 文件较大或 API 响应较慢"
    echo
    echo "建议:"
    echo "1. 使用更长的超时时间: export TIMEOUT=1800 (30分钟)"
    echo "2. 检查临时文件: ls -lh /tmp/git-translate-new-*"
    echo "3. 查看翻译日志: cat translation-*.log"
    echo "4. 如果临时文件有内容,可以手动复制到目标位置"
elif [ $EXIT_CODE -eq 0 ]; then
    echo "✓ 翻译成功完成"
else
    echo "❌ 翻译失败 (退出码: $EXIT_CODE)"
    echo "请查看日志文件了解详情"
fi

exit $EXIT_CODE
