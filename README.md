# cfblog

基于 Hugo 的个人博客，托管在 Cloudflare Pages。

## 技术栈

- [Hugo](https://gohugo.io/)：静态站点生成器
- [PaperMod](https://github.com/adityatelange/hugo-PaperMod)：Hugo 主题
- Cloudflare Pages：托管与自动部署
- 多语言：中文（基础语言） + 英文

## 环境要求

- 安装 [Hugo](https://gohugo.io/installation/)（推荐使用 extended 版本）

## 本地运行

```shell
# 连同 draft 草稿文件一起预览
hugo server -D
```

默认访问 `http://localhost:1313`。

## 常见 Hugo 命令

```shell
# 启动本地预览（包含草稿）
hugo server -D

# 仅预览已发布的文章
hugo server

# 指定端口 / 绑定局域网访问
hugo server -D -p 8080
hugo server -D --bind 0.0.0.0

# 新建文章（Page Bundle 形式）
hugo new post/2026/08/my-new-post/index.zh.md

# 生成静态站点到 public/ 目录
hugo

# 清除构建缓存
hugo --gc

# 仅构建指定语言（如英文）
hugo -l en

# 快速验证当前配置
hugo config

# 查看站点结构 / 输出统计信息
hugo list all
hugo list drafts
hugo list expired
hugo list future


## 新建文章

使用脚本一键创建：

```shell
./newpost.sh "文章标题"
```

脚本会按当前年月生成对应的 Page Bundle 和草稿文件：

- `content/post/<year>/<month>/<title>/index.zh.md`

也可以直接使用 Hugo 命令：

```shell
hugo new post/2026/08/my-new-post/index.zh.md
```

## Hugo Page Bundle 结构

```
content/
└── post/
    └── <year>/<month>/<title>/
        ├── index.<lang>.md   # 文章正文，<lang> 为语言代码
        └── <image>.webp      # 文章配图，尽量使用 webp 格式
```

支持的语言代码见 `hugo.yaml` 中的 `languages` 配置。新建的文章默认只有中文，如需多语言，手动添加对应文件（如 `index.en.md`）即可。

## 多语言

博客以中文为基础语言，英文内容使用 AI 翻译。翻译要求准确、流畅、简练，避免生硬的一比一直译，应结合目标语言语法和习惯使其更地道。使用 AI 翻译的文章需添加 `AI-Translated` 标签。

## 分类约定

| 分类 | 适用范围 |
| ---- | -------- |
| `program` | 编程相关 |
| `job` | 工作相关 |
| `life` | 生活相关 |
| `other` | 其它 |

## 部署

- 本地预览：`hugo server -D`
- 实际部署：`push` 到 GitHub 仓库，自动触发 Cloudflare Pages 构建部署