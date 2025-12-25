# Cloudflare Pages 部署指南

本指南将帮助你将「看见导航」部署到 Cloudflare Pages。

## 部署方式

### 方式一：通过 Cloudflare Pages 控制台部署（推荐）

这是最简单的部署方式，适合大多数用户。

#### 步骤

1. **Fork 本仓库**
   - 访问 [https://github.com/Seven-Steven/kanjian.la](https://github.com/Seven-Steven/kanjian.la)
   - 点击右上角的 `Fork` 按钮，将仓库 fork 到你的 GitHub 账户

2. **登录 Cloudflare**
   - 访问 [Cloudflare Pages](https://pages.cloudflare.com/)
   - 使用你的 Cloudflare 账户登录（如果没有账户，需要先注册）

3. **创建新项目**
   - 在 Cloudflare Pages 控制台，点击 `Create a project`
   - 选择 `Connect to Git`
   - 授权 Cloudflare 访问你的 GitHub 账户
   - 选择你 fork 的 `kanjian.la` 仓库

4. **配置构建设置**
   
   在构建配置页面，填写以下信息：

   - **项目名称 (Project name)**: 自定义你的项目名称（例如：`kanjian-la`）
   - **生产分支 (Production branch)**: `jekyll`
   - **框架预设 (Framework preset)**: 选择 `None` 或 `Jekyll`
   - **构建命令 (Build command)**:
     ```bash
     jekyll build --future
     ```
   - **构建输出目录 (Build output directory)**:
     ```
     _site
     ```

5. **环境变量（可选）**
   
   如果你需要配置环境变量，可以在 `Environment variables` 部分添加：
   
   - `JEKYLL_ENV`: `production`（可选，用于生产环境优化）

6. **开始部署**
   - 点击 `Save and Deploy` 按钮
   - Cloudflare Pages 会自动开始构建和部署
   - 首次部署通常需要 2-5 分钟

7. **访问你的网站**
   - 部署成功后，Cloudflare 会提供一个默认域名（格式：`your-project-name.pages.dev`）
   - 你可以在项目设置中添加自定义域名

### 方式二：使用 Wrangler CLI 部署

如果你熟悉命令行工具，可以使用 Wrangler CLI 进行部署。

#### 前置要求

- 已安装 Node.js (推荐 v16 或更高版本)
- 已安装 Ruby 和 Jekyll

#### 步骤

1. **安装 Wrangler CLI**
   ```bash
   npm install -g wrangler
   ```

2. **登录 Cloudflare**
   ```bash
   wrangler login
   ```

3. **构建网站**
   ```bash
   # 克隆仓库
   git clone https://github.com/Seven-Steven/kanjian.la.git
   cd kanjian.la
   
   # 使用 Docker 构建（推荐）
   docker run --rm -it \
     -v ${PWD}:/srv/jekyll \
     -v ${PWD}/_site:/srv/jekyll/_site \
     jekyll/builder:4 jekyll build --future
   
   # 或者使用本地 Jekyll
   bundle install
   jekyll build --future
   ```

4. **部署到 Cloudflare Pages**
   ```bash
   wrangler pages deploy _site --project-name=kanjian-la
   ```

## 构建配置详解

### 构建命令

```bash
jekyll build --future
```

- `jekyll build`: Jekyll 的构建命令，生成静态网站
- `--future`: 包含发布日期在未来的内容（如果有的话）

### 构建输出目录

```
_site
```

Jekyll 默认将生成的静态文件输出到 `_site` 目录。

### Ruby 版本

Cloudflare Pages 默认使用 Ruby 2.7.x。如果你需要指定 Ruby 版本，可以在项目根目录创建 `.ruby-version` 文件：

```
2.7.8
```

或者在环境变量中设置 `RUBY_VERSION`。

## 自动部署

配置完成后，每次你向 `jekyll` 分支推送代码，Cloudflare Pages 都会自动触发构建和部署。

你也可以在 Cloudflare Pages 控制台中：
- 查看部署历史
- 回滚到之前的版本
- 查看构建日志
- 配置预览部署（Preview Deployments）

## 自定义域名

1. 在 Cloudflare Pages 项目设置中，找到 `Custom domains` 部分
2. 点击 `Set up a custom domain`
3. 输入你的域名（例如：`kanjian.la`）
4. 按照提示配置 DNS 记录（如果域名已经在 Cloudflare 上，会自动配置）

## 常见问题

### Q: 构建失败，提示找不到 Jekyll

**A**: 确保构建命令正确，并且 Cloudflare Pages 能够自动安装 Ruby 依赖。检查 `Gemfile` 是否包含了所有必要的依赖。

### Q: 网站样式或图片无法加载

**A**: 检查 `_config.yml` 中的 `baseurl` 配置。对于 Cloudflare Pages，通常应该留空或设置为 `/`。

### Q: 构建时间过长

**A**: Jekyll 的构建速度取决于网站内容的数量。Cloudflare Pages 的免费套餐提供充足的构建时间，一般不会有问题。

### Q: 如何查看构建日志

**A**: 在 Cloudflare Pages 项目控制台中，点击具体的部署记录，可以查看详细的构建日志。

### Q: 能否使用其他分支进行部署

**A**: 可以。在项目设置中，你可以修改生产分支或配置预览分支。

## 高级配置

### 自定义构建脚本

如果你需要在构建过程中执行额外的操作（如图片压缩、资源优化等），可以创建一个构建脚本并在构建命令中调用。

例如，创建 `build.sh`:

```bash
#!/bin/bash
set -e

# 图片优化（如果需要）
# ./scripts/optimize-images.sh

# 构建 Jekyll
jekyll build --future

# 其他后处理操作
# ...
```

然后在 Cloudflare Pages 的构建命令中使用：

```bash
chmod +x build.sh && ./build.sh
```

### 环境变量使用

你可以在 Cloudflare Pages 中设置环境变量，并在 Jekyll 构建过程中使用：

```yaml
# _config.yml
google_analytics: <%= ENV['GOOGLE_ANALYTICS_ID'] %>
```

## 性能优化建议

1. **启用 HTTP/3 和 Brotli 压缩**：Cloudflare Pages 默认启用，无需额外配置

2. **使用 Cloudflare CDN**：Cloudflare Pages 自动通过全球 CDN 分发内容

3. **配置缓存规则**：在 Cloudflare 控制台中可以自定义缓存策略

4. **优化图片资源**：使用 Cloudflare Images 或在构建时压缩图片

## 资源链接

- [Cloudflare Pages 官方文档](https://developers.cloudflare.com/pages/)
- [Cloudflare Pages 部署指南](https://developers.cloudflare.com/pages/framework-guides/deploy-anything/)
- [Jekyll 官方文档](https://jekyllrb.com/)
- [Wrangler CLI 文档](https://developers.cloudflare.com/workers/wrangler/)

## 技术支持

如果你在部署过程中遇到问题，可以：

1. 查看本项目的 [Issues](https://github.com/Seven-Steven/kanjian.la/issues)
2. 参考 [Cloudflare Community](https://community.cloudflare.com/)
3. 提交新的 Issue 寻求帮助
