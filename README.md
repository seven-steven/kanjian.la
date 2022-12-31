# 看见导航

这是一个使用纯 HTML、CSS、JavaScript 开发的静态导航网站。

因为作者初学前端，想要学习各种原生的写法，以及 想要踩更多的坑。所以本项目未引入任何第三方的工具或者框架。仅此而已。

## 技术栈

- HTML
- CSS
- JavaScript
- [iconfont](https://www.iconfont.cn/)
- host by [Github Pages](https://docs.github.com/en/pages/quickstart)
- dns by [CloudFlare](https://cloudflare.com/)

## 编码历程与心得体会

### 响应式布局

1. 网页基准文字大小可以考虑使用 `vw`；
1. 网页内长度单位尽量统一使用 `rem`；
1. 如果子元素与父元素是相对长度，子元素可以偷懒使用 `em`；
1. 大部分浏览器限制了网页最小文字大小为 `12px`, 响应式布局需要考虑浏览器限制;
1. 依靠子元素宽高来弹性伸缩是不错的实践，但是留意宽高变动带来的不确定性。可以使用 `max-width` `min-width` `max-height` `min-height` 等保障基础布局；
