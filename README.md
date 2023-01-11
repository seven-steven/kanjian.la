# 看见导航

一个纯静态导航网站

因为作者初学前端，想要学习各种原生的写法，以及 想要踩更多的坑。所以本项目未引入任何第三方的 CSS 或者 JavaScript 框架。

## 技术栈

- Code by HTML & CSS & JavaScript
- Icon by [REMIX ICON](https://remixicon.com/)
- Templated by [Liquid](https://shopify.github.io/liquid/)
- Generate by [jekyll](https://jekyllrb.com/)
- Pipeline by [Github Actions](https://docs.github.com/actions)
- Host by [Github Pages](https://docs.github.com/en/pages/quickstart)
- DNS by [CloudFlare](https://cloudflare.com/)

## TODO LIST

- [ ] 移动端菜单优化 / 考虑添加返回顶部按钮
- [ ] 优化动画
- [ ] 关于我
- [ ] pc 菜单优化
- [ ] 添加专题
- [ ] 添加标签
- [ ] 支持分组 / alternatives
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

一般情况下，只需要关注 `_config.yml`, `data/sites.yml` 文件和 `assets/image/logo` 目录

- `_config.yml` 文件是站点的配置信息，包括站点名称、描述、favicon 等信息
- `data/sites.yml` 文件是站点内容配置文件，网站的所有内容都是依照这个文件编译生成
- `assets/image/logo` 目录用于存放导航站点 logo，然后被 `data/sites.yml` 引用

### 部署

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
