---
name: url-patrol
description: 巡检 kanjian.la 导航站链接的内容级异常（域名停放、被接管、商店下架、服务死亡、官方迁移、URL 配置错误），产出处置计划并执行修复。当用户要求巡检链接、排查或处置异常条目、检查失效/被接管的站点时使用。
---

# URL 内容级巡检

机械判定全部在 `scripts/patrol_urls.rb`——特征库、verdict 枚举、处置映射的唯一事实源是脚本常量，本文件不复述判定规则。本 skill 编排三件事：跑检测、复核模型判断队列、按计划执行处置。

巡检管线与既有的状态码管线（`check_urls.rb` + 连续失败 5 次 issue 机制）互补并存：内容级异常（停放/下架/接管）是确定性死亡证据，走本管线；一切不确定的不可达（`unreachable_*` 单次 5xx/超时/TLS 失败、`content_check_failed`）只给 `defer`，交回状态码管线按阈值计数——`remove` 建议只出自强证据（停放/停站/下架指纹、DNS 权威死亡、404/410 明确应答）。

本地运行先清掉不稳定代理（沙箱注入的 flaky 代理会导致 https 批量误判）：

## 1. 机械检测

```bash
env -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY ruby scripts/patrol_urls.rb --output /tmp/patrol.json
```

读 `summary.counts` 与 `model_review_queue`。完成判据：`results` 条数等于各 verdict 计数之和，`model_review_queue` 中每个 key 都能在 `results` 中找到对应条目。

## 2. 模型复核队列

对 `model_review_queue` 每条（verdict 为 `redirect_foreign` 或 `spa_shell`）：

1. 经渲染通道取内容（WebFetch 或 webReader；`spa_shell` 必须渲染后判断）
2. 判断最终站点与条目 title/description 的关系：同一产品（含改名、官方迁移域名）→ 输出建议新 URL；无关（停放轮换落点、赌博/广告/无关商业站）→ remove
3. 结论附证据（页面标题 + 关键内容摘要）；无证据不下结论

对抗复核：判定为 remove 的条目换一条独立访问路径复查一次，两路结论分歧时降级为 `defer` 并注明分歧。

完成判据：队列中每条都有 `{final_verdict: same_product | unrelated | needs_render_retry, evidence, suggested_url?}`，且每个 remove 结论均有两路一致证据。

## 3. 处置计划

汇总计划表，每条含 key、title、url、verdict、action、suggested_url、证据摘要：

- 机械层已建议的：`misconfigured` → replace_url（用 suggested_url）；`parked` / `unlisted` / `hosting_suspended` / `dead_dns` / `dead_tls` / `dead_http` → remove；`unreachable_5xx` / `unreachable_net` / `unreachable_tls` / `content_check_failed` / `cert_expired_live` → defer（交回状态码管线或下轮复查）
- 复核产出的：same_product → replace_url（suggested_url 为新域名）；unrelated → remove；needs_render_retry → defer
- `unlisted` 的替代品：先找在架替代（例：The Great Suspender → The Marvellous Suspender），确认在架后 replace_url；找不到 → remove

计划呈用户逐条确认。完成判据：用户对每条 action 有明确去留意见；未获确认的条目全部改落 `defer`。

## 4. 执行

```bash
ruby scripts/apply_patrol_plan.rb --plan plan.json --sites _data/sites.yml
```

plan.json 格式见 `scripts/apply_patrol_plan.rb` 头部注释。执行后立即验证：

```bash
ruby scripts/validate_sites.rb
git diff _data/sites.yml
```

完成判据：apply 输出全部 success/deferred；`validate_sites.rb` 退出码 0；diff 中每一处改动都能对应到计划中已确认的条目——出现计划外的改动即整体回退重查。

## 5. 收尾

报告处置数（remove / replace_url / defer 各几条）、孤儿 logo 清理数、剩余 defer 清单。提交信息对齐 `git log` 既有风格（`chore(navigation): ...` / `fix(navigation): ...`），经用户确认后提交。
