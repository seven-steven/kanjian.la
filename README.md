# 看见导航

[![Deploy to Cloudflare Pages](https://img.shields.io/badge/Deploy%20to-Cloudflare%20Pages-F38020?style=for-the-badge&logo=cloudflare&logoColor=white)](./CLOUDFLARE_DEPLOYMENT.md)

一个纯静态导航网站

因为作者初学前端，想要学习各种原生的写法，以及 想要踩更多的坑。所以本项目未引入任何第三方的 CSS 或者 JavaScript 框架。

## 技术栈

- Code by HTML & CSS & JavaScript
- Edit by [Visual Studio Code](https://code.visualstudio.com/)
- Icon by [REMIX ICON](https://remixicon.com/)
- Templated by [Liquid](https://shopify.github.io/liquid/)
- Generate by [jekyll](https://jekyllrb.com/)
- Pipeline by [Github Actions](https://docs.github.com/actions)
- Host by [Github Pages](https://docs.github.com/en/pages/quickstart) / [Cloudflare Pages](https://pages.cloudflare.com/)
- DNS by [CloudFlare](https://cloudflare.com/)
- ICON Vectorizer by [Vectorizer.AI](https://vectorizer.ai/)

## 分支说明

仓库维护了两条分支，对应站点的两种实现方式：

- `static`：纯静态源站点。网站内容直接写在 `index.html` 与 `assets/` 中，不经过任何构建步骤。
- `jekyll`：使用 jekyll 模板引擎渲染的站点（默认分支，线上部署来源）。网站内容维护在 `_data/sites.yml`，由 `_layouts/` 与 `_includes/` 下的模板渲染生成。

## TODO LIST

- [ ] 移动端菜单优化 / 考虑添加返回顶部按钮
- [ ] 优化动画
- [ ] 关于我
- [ ] pc 菜单优化
- [ ] 添加专题
- [ ] 添加标签
- [ ] 支持分组 / alternatives
- [ ] 发布 jekyll 主题
- [ ] 自动获取 item 图标和简介
- [ ] 定期巡检，移除失效站点
- [x] 感谢设计师 [@Huazi](https://huazi.space/) 的建议，给 PC 导航栏加上了磨砂效果
- [x] 借助 `content-visibility: auto;` 优化页面加载速度
- [x] 渐变背景 & 固定背景
- [x] 添加 footer
- [x] 高分屏适配
- [x] ~~添加微信分享图标~~
- [x] 借用暗锚修正因 stick 布局造成的 a 标签 anchor 定位偏移
- [x] pc 菜单栏优化 stick 布局
- [x] 添加 icon title & site-item title
- [x] 完善 README 使用手册
- [x] 使用 jekyll 动态生成站点内容
- [x] 添加响应式布局
- [x] 基础静态页面编写

## HOW TO USE

### 开发

#### 预览

1. 克隆仓库到本地 `git clone https://github.com/Seven-Steven/kanjian.la.git`
1. 进入代码目录 `cd kanjian.la`
1. 使用 Docker 运行代码

   ```bash
   docker run -it \
   --rm \
   -v=$PWD:/srv/jekyll \
   -p 4000:4000 \
   jekyll/jekyll:4 jekyll serve
   ```

1. 访问 [http://localhost:4000](http://localhost:4000) 即可开启实时预览

#### [目录结构](https://jekyllrb.com/docs/structure/)

```text
├── assets    站点静态文件
│   ├── css     站点 CSS 样式目录
│   └── image     站点图片
│            └── logo     导航站点 logo 文件目录
├── _config.yml     网站配置
├── _data
│   └── sites.yml     站点数据
├── Gemfile     ruby 依赖定义文件
├── _includes     页面模板
├── index.html      首页
├── _layouts      页面布局
│   ├── default.html      默认布局
│   └── index.html      首页布局
├── README.md     项目说明
└── _site     编译文件目录，可用于发布的静态文件
```

一般情况下，只需要关注 `_config.yml`, `_data/sites.yml` 文件和 `assets/image/logo` 目录

- `_config.yml` 文件是站点的配置信息，包括站点名称、描述、favicon 等信息
- `_data/sites.yml` 文件是站点内容配置文件，网站的所有内容都是依照这个文件编译生成
- `assets/image/logo` 目录用于存放导航站点 logo，然后被 `_data/sites.yml` 引用

#### 站点数据结构与图标语义

导航内容维护在 `_data/sites.yml` 中。顶层分类使用 `name` 和 `icon` 描述分类名称与图标，并通过 `links`（站点列表）或 `sub`（子分类）组织内容。

每个站点条目支持以下字段：

| 字段              | 必填 | 说明                                                                                             |
| ----------------- | ---- | ------------------------------------------------------------------------------------------------ |
| `title`           | 是   | 站点显示名称。                                                                                   |
| `url`             | 是   | 站点主链接，使用完整的 HTTP(S) URL。                                                             |
| `description`     | 否   | 站点简介，建议用一句话说明主要用途或特色。                                                       |
| `logo`            | 是   | 站点 Logo 文件名。文件存放在 `assets/image/logo/` 中，此处仅填写文件名，例如 `example.com.svg`。 |
| `icons`           | 否   | 站点的状态和补充信息图标，由 `status`、`info` 两组图标对象组成。                                 |
| `icons.*[].icon`  | 是   | Remix Icon 的 class 名称，例如 `ri-github-fill`。                                                |
| `icons.*[].title` | 否   | 图标的悬停提示和具体语义；同一图标表达多种含义时，以此字段为准。建议填写。                       |
| `icons.*[].url`   | 否   | 点击图标后打开的相关链接，使用完整的 HTTP(S) URL。                                               |

`status` 表示站点自身的语言、访问或收费状态，显示在 Logo 左侧；`info` 表示与站点相关的项目、文档或其他资源，显示在 Logo 右侧。没有相关图标时可以省略对应分组或整个 `icons` 字段。

```yaml
- title: 示例站点
  url: https://example.com/
  description: 用一句话说明站点用途
  logo: example.com.svg
  icons:
    status:
      - icon: ri-english-input
        title: 英文
      - icon: ri-money-cny-circle-line
        title: 收费情况
        url: https://example.com/pricing
    info:
      - icon: ri-book-2-line
        title: 文档
        url: https://example.com/docs
      - icon: ri-github-fill
        title: 开源项目
        url: https://github.com/example/example
```

##### 状态图标（`status`）

| 图标                       | 语义                                                                      |
| -------------------------- | ------------------------------------------------------------------------- |
| `ri-english-input`         | 站点的主要语言。具体语言通过图标的 `title` 标明。                         |
| `ri-send-plane-fill`       | 需要国际互联网访问。                                                      |
| `ri-money-cny-circle-line` | 收费情况，例如收费、免费方案或免费试用；具体情况通过图标的 `title` 标明。 |

##### 信息图标（`info`）

| 图标                  | 语义                                            |
| --------------------- | ----------------------------------------------- |
| `ri-github-fill`      | 对应的开源项目或源码仓库。                      |
| `ri-exchange-line`    | 功能类似的项目或替代方案。                      |
| `ri-book-2-line`      | 当前 `subject` 的文档站点。                     |
| `ri-computer-line`    | Demo 或在线演示站点。                           |
| `ri-home-office-line` | 官方网站。                                      |
| `ri-sparkling-2-line` | 其他补充信息；具体含义通过图标的 `title` 标明。 |
| `ri-translate`        | 站点对应的翻译项目或其他语言版本。              |

上述语义表仅适用于站点条目中的 `icons.status` 和 `icons.info`。顶层分类的 `icon` 仅作为分类的视觉标识，不受此表约束。

##### 可自动提升的替代站点

`icons.info` 中的 `ri-exchange-line` 通常只表示功能类似的项目。若希望主站持续不可访问时，URL 维护 Action 自动将其中一个替代项目提升为新的主站，该图标对象必须显式提供完整的主站数据：

- `title`：替代站点名称；
- `url`：替代站点主链接；
- `description`：替代站点简介；
- `logo`：已经提交到 `assets/image/logo/` 的 Logo 文件名；
- `icons`：替代站点自己的 `status` 和 `info` 图标，可省略或留空。

```yaml
- title: 原站点
  url: https://old.example.com/
  description: 原站点简介
  logo: old.example.com.svg
  icons:
    status:
    info:
      - icon: ri-exchange-line
        title: 替代站点
        url: https://replacement.example.com/
        description: 替代站点简介
        logo: replacement.example.com.svg
        icons:
          status:
            - icon: ri-english-input
              title: 英文
          info:
            - icon: ri-github-fill
              title: 开源项目
              url: https://github.com/example/replacement
```

自动提升仅在以下条件全部满足时执行：失败对象是主站链接；当前条目中恰好有一个同时完整提供 `title`、`url`、`description` 和 `logo` 的 `ri-exchange-line` 候选；候选 URL 规范化后与失败 URL 不同；候选 Logo 文件安全且存在；批准处理时重新检查候选 URL 仍可访问。提升后，主条目的 `title`、`url`、`description`、`logo` 和 `icons` 全部使用候选显式提供的数据，不继承原站点字段；原失效 URL 和已提升的 `ri-exchange-line` 图标不会保留。

Action 不会从网页、搜索结果或 AI 推断替代 URL、简介、Logo 或 icons，也不会自动下载 Logo。没有唯一完整候选或候选 URL 不可访问时，工作流将继续按现有规则删除持续失效的主站条目。字段不完整的 `ri-exchange-line` 仅作为替代链接展示，即使包含 `logo` 等附加信息也不会触发自动提升。

### 导航维护自动化

仓库已实现两类导航维护自动化；自动化的目标是减少重复操作，不替代维护者审核。

#### URL 巡检与 Issue 生命周期

- `.github/workflows/url-check.yml` 每日 UTC 03:23 运行，也可在 Actions 页面通过 `workflow_dispatch` 手动运行；相关数据、检查脚本或工作流变更推送时也会触发。
- 巡检会先执行 URL 检查单元测试，再以超时 10 秒、重试 2 次检查 `_data/sites.yml` 中完整的 HTTP 或 HTTPS 外部 URL；HTTP 协议本身不会被视为异常。
- 每个被检查 URL 以稳定键关联一个 Issue；同一 URL 连续出现明确失效达到阈值（见下）才会创建或更新 Issue，并添加 `url-check`、`automated`、`needs-review` 标签。明确失效仅包括 URL 静态格式错误，以及已收到的非豁免 HTTP 4xx/5xx 响应。重复 Issue 会保留最早的一项并关闭其余项。
- Issue 会记录连续明确失效次数。第 1–4 次由 Actions cache 进行 best-effort 计数（不会创建 Issue）；`main` 或 `icon` URL 连续明确失效 5 次后才创建 Issue 并进入可批准状态。DNS 解析失败、TLS 验证失败、超时、连接错误，以及因解析到非公网地址而被 SSRF 防护拒绝，都只表示当前巡检环境无法验证：它们会清除连续失效计数，不会创建可批准 Issue，也不能作为删除依据。cache 是尽力而为，丢失只会让未达阈值的失败重新计数、推迟 Issue 创建，不会提前创建或处理链接。仓库所有者可添加 `agent:approved`，由确定性工作流重新检查当前 URL 和当前导航数据。只有 URL 仍为明确失效且恰好匹配一个导航条目时才会修改数据：`main` URL 优先提升该条目中唯一、完整且重新检查为可访问的 `ri-exchange-line` 替代站点，否则删除整个站点条目；`icon` URL 仅删除该图标条目（站点本身保留）。已恢复 URL、巡检环境无法验证、次数不足、缺失或多重匹配均不修改数据。
- URL 处置不调用 Claude，也不从外部内容猜测替代 URL 或元数据；自动提升只使用 `_data/sites.yml` 中预先声明的完整候选。Claude Code Action 仍仅处理所有者通过导航 Issue Form 提交的明确 add/update/remove 请求。
- URL 恢复可访问时，自动追加恢复说明并关闭对应 Issue；URL 已从导航移除或被替代时，也会追加说明并关闭对应 Issue。401、403、412、429 被视为可访问但受限，不会作为失效处理。URL 处置 PR 由所有者审核合并后，`jekyll` push 会自动部署 Pages、同步 Webstack，并再次巡检以关闭原 Issue。

#### 维护者申请到 PR 的流程

1. 仓库所有者使用“导航收录申请”Issue Form 提交一个 `add`、`update` 或 `remove` 请求。表单初始带有 `navigation-request` 和 `needs-owner-review` 标签。
2. 所有者核对请求后手动添加 `agent:approved`。只有 Issue 仍为 open、由仓库所有者创建，并同时具有 `navigation-request` 与 `agent:approved` 标签时，导航 Agent 才会启动。
3. Claude Code Action 把 Issue 视为不可信输入，只执行一个已批准的操作：最小化修改 `_data/sites.yml`；只有明确提供公开 HTTPS Logo URL 时，才可额外下载一个位于 `assets/image/logo/` 直接子路径的 Logo。
4. Action 完成后，工作流以确定性步骤依次运行 Ruby 测试、`ruby scripts/validate_sites.rb`、`ruby scripts/check_agent_diff.rb --base origin/jekyll` 与 Git diff 检查；Agent 本身无权执行这些验证、Git/GitHub 操作或读取凭据。
5. 验证通过后，工作流提交并推送固定分支 `agent/issue-<Issue 编号>`，创建或更新以 `jekyll` 为基准的 PR；交付完成后申请 Issue 的标签从 `needs-owner-review` 改为 `agent:completed`。PR 仍须由所有者按仓库治理规则审核后合并。

本地复现验证可运行：

```bash
# 执行所有 Ruby 测试
find test -type f -name '*_test.rb' -print0 | sort -z | xargs -0 -r -n1 ruby

# 仅检查 URL 检查器
ruby -Itest test/check_urls_test.rb

# 校验导航数据
ruby scripts/validate_sites.rb

# 在 Agent 分支审计允许的差异
ruby scripts/check_agent_diff.rb --base origin/jekyll

# 构建 Jekyll 站点
jekyll build --future
```

CI 还会使用 `jekyll/builder:4.2.0` 容器执行 `jekyll build --future`，以与部署构建保持一致。

#### Claude Provider 与凭据

导航 Agent 的 Claude Provider 使用 Anthropic **Messages endpoint**，通过 `Authorization: Bearer` 认证；不使用 OpenAI 兼容的 `/chat/completions` endpoint，也不将其用于 Claude Code Action。

请在仓库 Actions 的 Variables / Secrets 中配置占位符对应的值，不要将真实凭据写入仓库、Issue、PR 或 README：

| 位置           | 名称                       | 用途                                                                                                       |
| -------------- | -------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Variable       | `ANTHROPIC_BASE_URL`       | Anthropic Messages endpoint 的基础地址                                                                     |
| Variable       | `ANTHROPIC_MODEL`          | 导航 Agent 使用的 Claude 模型                                                                              |
| Secret         | `ANTHROPIC_AUTH_TOKEN`     | Bearer 认证令牌；同时传入 Action 的启动认证输入，但实际网关认证由该变量生成 `Authorization: Bearer` Header |
| Secret（可选） | `ANTHROPIC_CUSTOM_HEADERS` | Provider 所需的附加请求头                                                                                  |

交付分支和 PR 不再使用 `NAVIGATION_BOT_TOKEN`。改用 GitHub App installation token：先在 GitHub 创建 App；创建完成后进入该 App 的 **Install App**（或 **Configure**）页面，在安装时选择 **Only select repositories**，仅选择 `seven-steven/kanjian.la`，不要选择 **All repositories**。随后生成私钥，并将 App 的 Client ID 与私钥分别保存为 `NAVIGATION_APP_CLIENT_ID` 和 `NAVIGATION_APP_PRIVATE_KEY`。工作流通过固定版本的 `actions/create-github-app-token` 创建短期 installation token，供 Claude Action 读取 Issue 上下文，并用于推送 `agent/issue-<编号>` 分支及创建/更新 PR。

该 GitHub App 的最小仓库权限为：

- **Contents: Read and write**：读取仓库并推送 Agent 分支；
- **Issues: Read-only**：向 Claude Action 提供已批准 Issue 的上下文；
- **Pull requests: Read and write**：创建或更新 PR。

不要为这个 App 授予超出上述用途的权限。现有 `TOKEN` 不属于导航 Agent 凭据，仍只用于部署工作流将站点数据同步至 `seven-steven/webstack-jekyll`（Webstack sync）。

#### 治理与合并保护

- `.github/CODEOWNERS` 要求 `@Seven-Steven` 审核 `.github/`、Issue Form、工作流、Agent 提示词、`_config.yml`、`_data/sites.yml` 与 `assets/image/logo/`。
- 面向 `jekyll` 的 Agent PR 会运行 `Enforce navigation agent PR scope`：人工导航分支使用 `agent/issue-<编号>`，URL 移除分支使用 `agent/url-check-issue-<编号>`；两者都必须来自本仓库并关联仍获批准的 Issue。人工导航 PR 仅可修改 `_data/sites.yml` 和直接子级 Logo，URL 移除 PR 仅可修改 `_data/sites.yml`。
- 面向 `jekyll` 的内容验证检查为 `Validate navigation data`，包含全部 Ruby 测试、站点数据校验与 Jekyll Docker 构建；这是 Agent PR 需要通过的确定性检查。
- `jekyll` 分支的 ruleset / required checks 应要求所有者的 CODEOWNERS 审批，并要求上述 `Enforce navigation agent PR scope` 与 `Validate navigation data` 检查通过后才能合并。请在 GitHub 仓库设置中保持这些保护启用。

### 部署

#### 部署到 Cloudflare Pages

Cloudflare Pages 提供了免费、快速且易用的静态网站托管服务。

**快速部署步骤：**

1. Fork 本仓库到你的 GitHub 账户
2. 登录 [Cloudflare Pages](https://pages.cloudflare.com/)
3. 创建新项目并连接到你的 GitHub 仓库
4. 使用以下构建配置：
   - **生产分支**: `jekyll`
   - **构建命令**: `jekyll build --future`
   - **构建输出目录**: `_site`
5. 保存并部署

详细的部署指南和故障排查，请参考 [Cloudflare Pages 部署文档](./CLOUDFLARE_DEPLOYMENT.md)。

#### 手动部署到其他服务器

1. 使用 Docker 编译代码

   ```bash
   docker run --rm -it \
     -v ${PWD}:/srv/jekyll \
     -v ${PWD}/_site:/srv/jekyll/_site \
     jekyll/builder:4 /bin/bash -c '
       gem sources -r https://rubygems.org/ -a https://gems.ruby-china.com/ && \
       bundle config mirror.https://rubygems.org https://gems.ruby-china.com && \
       bundle config --delete "mirror.https://rubygems.org" && \
       jekyll build --future'
   ```

1. 发布 `_site` 目录到服务器

## 编码历程与心得体会

### 经验漫谈

1. 编程的过程中有两次创造：第一次在脑海，创造架构或者说思路；第二次在指尖，把思路翻译成代码。不可操之过急，妄想一蹴而就。

### 响应式布局

1. 网页基准文字大小可以考虑使用 `vw`；
1. 网页内长度单位尽量统一使用 `rem`；
1. 如果子元素与父元素是相对长度，子元素可以偷懒使用 `em`；
1. 大部分浏览器限制了网页最小文字大小为 `12px`, 响应式布局需要考虑浏览器限制;
1. 依靠子元素宽高来弹性伸缩是不错的实践，但是留意宽高变动带来的不确定性。可以使用 `max-width` `min-width` `max-height` `min-height` 等保障基础布局；
1. 尽可能早，用更多不一样的数据测试，能够发现更多问题。
1. 典型的设备断点并不能适配所有情况，可能还是要按需调整。比如 1920x1080 在 1/2 分屏状态下视口宽度是 960px，有可能需要考虑这种特殊情况。

### 其他

1. `inline` 元素不支持 `transform`，需要将其 `display` 设置为 `inline-block` 或者 `block`；
1. 使用暗锚可以修复因为 `fix` 或者 `stick` 布局带来的 anchor 定位偏移。[参考文档](https://segmentfault.com/q/1010000000124208)
1. 尽可能引入少的静态资源，尽量按需引入。能够显著提升页面加载速度。
1. 无法直接使用 `backdrop-filter` 属性同时对父子元素创建模糊效果，受 [解决父级使用backdrop-filter后，子级再使用不生效](https://ylface.com/course/2821.html) 启发，使用下面的代码解决了问题。

```css
.blur::before {
  content: "";
  position: absolute;
  top: 0;
  right: 0;
  bottom: 0;
  left: 0;
  -webkit-backdrop-filter: blur(0.1rem);
  backdrop-filter: blur(0.1rem);
}
```
