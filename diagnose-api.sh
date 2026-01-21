#!/bin/bash
# API 诊断脚本 - 检查 OpenAI API 配置

set -a && source ../../.env && set +a

echo "=== API 配置诊断 ==="
echo

# 检查环境变量
echo "1. 检查环境变量:"
if [ -z "$OPENAI_API_KEY" ]; then
    echo "   ❌ OPENAI_API_KEY 未设置"
else
    echo "   ✓ OPENAI_API_KEY 已设置 (长度: ${#OPENAI_API_KEY})"
fi

if [ -z "$OPENAI_BASE_URL" ]; then
    echo "   ❌ OPENAI_BASE_URL 未设置"
else
    echo "   ✓ OPENAI_BASE_URL: $OPENAI_BASE_URL"
fi

if [ -z "$OPENAI_MODEL" ]; then
    echo "   ❌ OPENAI_MODEL 未设置"
else
    echo "   ✓ OPENAI_MODEL: $OPENAI_MODEL"
fi

echo
echo "2. 测试 API 连接:"

# 构造测试请求
API_ENDPOINT="${OPENAI_BASE_URL}/chat/completions"

# 发送测试请求
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -H "User-Agent: git-translate/1.0" \
  -d '{
    "model": "'"${OPENAI_MODEL}"'",
    "messages": [{"role": "user", "content": "test"}],
    "temperature": 0.3
  }' 2>&1)

# 分离响应体和状态码
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n -1)

echo "   HTTP 状态码: $HTTP_CODE"
echo "   响应内容:"
echo "$BODY" | sed 's/^/   /'

echo
echo "3. 诊断结果:"
if [ "$HTTP_CODE" = "401" ]; then
    echo "   ❌ 认证失败 (401)"
    echo
    echo "   可能的原因:"
    echo "   - API Key 无效或过期"
    echo "   - API Key 格式不正确"
    echo "   - Base URL 不正确 (当前: $OPENAI_BASE_URL)"
    echo "   - 账户余额不足或已过期"
    echo
    echo "   解决方法:"
    echo "   1. 检查 .env 文件中的 OPENAI_API_KEY 是否正确"
    echo "   2. 检查 OPENAI_BASE_URL 是否与 API 提供商匹配"
    echo "   3. 确认 API 账户状态和余额"
    echo "   4. 如果使用第三方 OpenAI 兼容 API,确保其兼容性"
elif [ "$HTTP_CODE" = "200" ]; then
    echo "   ✓ API 连接成功"
else
    echo "   ⚠ HTTP 状态码: $HTTP_CODE"
    echo "   请检查响应内容了解详情"
fi

echo
echo "=== 诊断完成 ==="
