+++
date = '2026-07-09T21:50:41+08:00'
lastmod = '2026-07-09T21:50:41+08:00'
draft = false
isCJKLanguage = true
title = '发包到 PyPI: 以 quick-json-diff 为例'
description = '如何发布自己的 Python 库到 PyPI: 以 quick-json-diff 为例'
summary = '如何发布自己的 Python 库到 PyPI: 以 quick-json-diff 为例'
categories = ["program"]
tags = ["python"]
keywords = ["python"]
slug = 'publish-quick-json-diff-to-pypi'
+++

## 前言

之前写过一篇如何用 Python 标准库快速比较两个巨复杂的 JSON 之间的内容值的差异（不是简单对比行之间的差距，而是对比那些值有差异），主要用在某个内部服务中做版本管理的。使用效果大概是这样的：

```shell
# 文件行数为21772行
$ wc -l test_left.json
21772 test_left.json

# 要尽可能快的比较出来
$ time json-diff test_left.json test_right.json
[
    {
        "path": "variables[3].spec.sort",
        "kind": "modified",
        "left": "alphabeticalAsc123",
        "right": "alphabeticalAsc"
    }
]
# 耗时 0.04 秒
json-diff test_left.json test_right.json  0.04s user 0.02s system 99% cpu 0.055 total
```

当时有人问能否打包发到 PyPI 上，于是我动手稍微改了下，做了一半，后来给其他事情耽搁了，拖了那么久，也忘了 PyPI 怎么发包的了，正好借此整理下步骤。


想尝试的小伙伴也可以安装下试试：

```bash
python -m pip install quick-json-diff
```

## 代码

### pyproject.toml

有多种项目构建方式，基于 `pyproject.toml` 是其中一种。如果用 `uv` 的话，那么基于 `uv` 生成的 `pyproject.toml` 稍作修改会更方便点。

基本需要的配置如下，其中 `[build-system]` 用来声明构建后端，可替换为其它多种构建后端，具体可见底部关于 pyproject.toml 的参考链接。

```toml
[project]
name = "quick-json-diff"
version = "1.0.0"
description = "Compare two JSON files quickly using Python standard library."
readme = "README.md"
requires-python = ">=3.9"
license = { file = "LICENSE" }

[build-system]
requires = ["setuptools >= 77.0.3"]
build-backend = "setuptools.build_meta"
```

### 代码布局

对于我这个 SDK，我用的是`src/` 结构布局，也就是：

```
└─ src
  └─ quick_json_diff
```

## 本地构建

1. 安装构建工具。`build` 用来构建，`twine` 用来上传 PyPI

```bash
python -m pip install --upgrade build twine
```

2. 构建。构建结果会生成在 `dist/` 目录下

```shell
python -m build
```

3. 上传 PyPI 前，用 `twine` 检查包元数据

```bash
$ twine check dist/*
Checking dist/quick_json_diff-1.0.0-py3-none-any.whl: PASSED
Checking dist/quick_json_diff-1.0.0.tar.gz: PASSED
```

上传

```shell
# 上传 TestPyPI
twine upload --repository-url https://test.pypi.org/legacy/ dist/*

# 从 TestPyPI 下载测试
pip install -i https://test.pypi.org/simple/ quick-json-diff

# 上传 PyPI
twine upload dist/*
```

4. 本地安装测试

```bash
python -m pip install dist/quick_json_diff-1.0.0-py3-none-any.whl
```

## 发布到 PyPI

上传到 PyPI 之前，最好先发布到 TestPyPI 作为测试，验证展示页和安装体验。

1. 先到 [test.pypi.org](https://test.pypi.org) 和 [pypi.org](https://pypi.org) 注册账号。分别创建 API Token
2. 发布到 TestPyPI。上传时会提示输入 API Token

```bash
twine upload --repository-url https://test.pypi.org/legacy/ dist/*
```

3. 测试安装

```bash
python -m pip install \
  -i https://test.pypi.org/simple/ \
  quick-json-diff
```

4. 前面测试没问题的话，再上传到 PyPI

```bash
twine upload dist/*
```

5. 结束

## 补充

- 后续发新版，需要修改 `pyproject.toml` 中的 `version`，然后重新构建、上传。

## 参考

- pyproject.toml 官方教程: [https://packaging.python.org/en/latest/guides/writing-pyproject-toml/](https://packaging.python.org/en/latest/guides/writing-pyproject-toml/)