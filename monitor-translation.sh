#!/bin/bash
# 翻译进度监控脚本

echo "=== 翻译进度监控 ==="
echo

while true; do
    clear
    echo "=== 翻译进度监控 ==="
    echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
    echo

    # 检查临时文件
    temp_files=$(ls -lh /tmp/git-translate-new-* 2>/dev/null | wc -l)
    if [ $temp_files -gt 0 ]; then
        echo "临时文件数量: $temp_files"
        echo
        ls -lh /tmp/git-translate-new-* 2>/dev/null
        echo
    fi

    # 检查已完成的文件
    echo "已翻译文件:"
    ls -lh *.md 2>/dev/null | awk '{print $9, $5, $6, $7, $8}'
    echo

    # 检查 git-translate 进程
    pid=$(pgrep -f "git-translate update")
    if [ -n "$pid" ]; then
        echo "✓ git-translate 进程运行中 (PID: $pid)"
        echo "  CPU: $(ps -p $pid -o %cpu= | tr -d ' ')%, 内存: $(ps -p $pid -o %mem= | tr -d ' ')%"
    else
        echo "⚠ git-translate 进程未运行"
    fi

    echo
    echo "按 Ctrl+C 退出监控"

    sleep 5
done
