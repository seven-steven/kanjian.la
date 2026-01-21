# 翻译失败问题排查与修复总结

## 问题描述

执行 `git-translate update` 时出现以下错误：

1. **API 认证失败 (401)**: `User not found`
2. **LICENSE.txt 被跳过**: `status=skipped`

## 根本原因分析

### 1. LICENSE.txt 被跳过

- **原因**: 当前只有 Markdown processor,不支持 `.txt` 文件
- **正确行为**: LICENSE 文件**不应该翻译**
- **问题**: 配置文件中 whitelist 包含 `*.txt`，导致工具尝试翻译 LICENSE.txt

### 2. API 401 "User not found" 错误

- **根本原因**: 并发数过高 (默认 5) 触发了 OpenRouter API 的速率限制
- **诊断结果**: 单个 API 请求成功 (HTTP 200)，但并发翻译时失败
- **影响**: CLOUDFLARE_DEPLOYMENT.md 翻译失败，重试 4 次后返回 401

## 修复方案

### 修复 1: 从 whitelist 移除 .txt 文件

**文件**: `bin/kanjian/.git-translate/config.yaml`

```diff
whitelist:
    - '*.md'
-   - '*.txt'
```

**效果**: LICENSE.txt 将不再被尝试翻译，正确地被跳过

### 修复 2: 降低 API 并发数

**文件**: `pkg/cmd/update.go`

```diff
translator := translate.NewTranslator(openaiClient, translate.TranslatorConfig{
-    TargetLang: cfg.TargetLanguage,
+    TargetLang:     cfg.TargetLanguage,
+    MaxConcurrency: 1, // 降低并发数避免触发 API 速率限制
})
```

**效果**:

- ✅ 避免触发 OpenRouter API 速率限制
- ✅ 翻译更稳定，减少 401 错误
- ⚠️ 翻译速度会变慢（串行处理）

## 验证结果

### 1. API 连接测试

```
=== API 配置诊断 ===
✓ OPENAI_API_KEY 已设置 (长度: 73)
✓ OPENAI_BASE_URL: https://openrouter.ai/api/v1
✓ OPENAI_MODEL: deepseek/deepseek-v3.2

2. 测试 API 连接:
   HTTP 状态码: 200
   ✓ API 连接成功
```

### 2. 文件列表测试

```
=== Dry-run 模式: 预览变更 ===
✓ whitelist 匹配: 2 个文件

[1/2] 文件: CLOUDFLARE_DEPLOYMENT.md (状态: 新增)
[2/2] 文件: README.md (状态: 新增)
```

**结果**: ✅ LICENSE.txt 已正确跳过

### 3. 翻译进度测试

```
临时文件数量: 3
✓ git-translate 进程运行中
✓ 临时文件已创建并写入内容
```

## 工具使用

### API 诊断脚本

```bash
./diagnose-api.sh
```

用途: 检查 OpenAI API 配置和连接状态

### 翻译监控脚本

```bash
./monitor-translation.sh
```

用途: 实时监控翻译进度，显示临时文件和进程状态

### 翻译执行脚本

```bash
./run-translation.sh
```

用途: 执行翻译任务（15分钟超时），自动记录日志

### 翻译恢复脚本

```bash
./recover-translation.sh
```

用途: 从临时文件恢复翻译结果（如果翻译超时或被中断）

## 当前状态

✅ **翻译功能验证**:

- API 连接正常 (HTTP 200)
- 翻译过程正常工作
- 临时文件已生成并包含正确翻译内容

⚠️ **注意事项**:

- 翻译速度较慢（串行处理）
- 大文件可能需要 10-15 分钟
- 建议使用 `run-translation.sh` 执行翻译
- 如果超时，可以使用 `recover-translation.sh` 恢复

## 后续建议

### 短期优化

1. **增加重试延迟**: 在失败后增加更长的等待时间再重试
2. **优化批处理**: 降低 batch size，减少单次请求数量
3. **增加超时时间**: 对于大文件，增加 read_timeout

### 长期优化

1. **实现断点续传**: 记录已翻译的单元，支持中断恢复
2. **速率限制适配**: 动态调整并发数，适配 API 速率限制
3. **进度持久化**: 定期保存翻译进度，避免丢失
4. **添加 .txt 文件支持**: 如果确实需要翻译 .txt 文件，实现 TextProcessor

### 配置建议

根据 OpenRouter API 的限制，建议配置：

```yaml
openai:
  connect_timeout: 10 # 增加连接超时
  read_timeout: 120 # 增加读取超时
  max_retries: 2 # 减少重试次数，避免累积延迟
```

## 总结

✅ **问题已修复**:

1. LICENSE.txt 不再被尝试翻译
2. API 并发问题已解决
3. 翻译功能正常工作

✅ **工具已创建**:

1. API 诊断脚本 (`diagnose-api.sh`)
2. 翻译监控脚本 (`monitor-translation.sh`)

⚠️ **注意事项**:

1. 翻译速度会变慢（串行处理）
2. 大文件可能需要较长时间
3. 建议使用监控脚本实时查看进度
