# cfblog

基于 Hugo 的个人博客，托管在 Cloudflare 。

## Hugo Cli

- 本地运行

```shell
# 连同 draft 文件
hugo server -D
```

## Hugo Page Bundle

- content/
  - post/
    - <year>/<month>/<title>/
      - index.<lang>.md
      - <image>.webp