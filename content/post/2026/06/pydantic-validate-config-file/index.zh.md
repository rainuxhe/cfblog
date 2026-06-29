+++
date = '2026-06-29T23:18:44+08:00'
draft = false
title = 'Pydantic 校验配置文件'
description = '在使用配置文件的配置类中，引入pydantic做参数校验'
summary = '使用Pydantic校验配置文件参数'
categories = [
    "program"
]
tags = [
    "python"
]
keywords = ["pydantic", "python"]
slug = 'pydantic-validate-config-file'
+++

## 前言

最近很多新项目使用环境变量作配置，尤其是部署在k8s上的项目，把 configmap 或者 secret 直接塞到 pod 环境变量里面，再引入`pydantic-settings`做参数校验，用起来特别方便。但`pydantic-settings`是环境变量优先的，而对于大一点的项目，配置项可能上百个，我还是比较习惯用配置文件，把相关配置嵌套起来方便管理。

以前写基于文件的配置类的时候，我是先写各种`Mixin`类，其中取值方法里面写校验逻辑，然后组装成一个`Config`类。习惯之后觉得也还行，直到今天加一组配置的时候才想起来：不对，既然项目（基于FastAPI）都已经引入pydantic了，我干嘛不直接用pydantic做参数校验？！

本文以`toml`格式配置文件（其实就是加载toml为字典交给pydantic，换成json和yaml用法是近似的）为例，搭配`pydantic`实现带有参数校验功能的配置类。

## 安装依赖

只需要安装`pydantic`即可，不用安装`pydantic-settings`。Python 3.11 后标准库自带`tomllib`用来解析 toml 文件。

```shell
uv add -U pydantic
# python -m pip install -U pydantic
```

## 配置文件示例

以下为部分配置文件内容，实际项目中肯定会有更多配置项：

```toml
[service]
  host = "127.0.0.1"
  port = 8000
  env = "dev"  # dev, prod

[service.log]
  level = "DEBUG"  # DEBUG, INFO, WARNING, ERROR
  output = "BOTH"  # STDOUT, FILE, BOTH
  dir = "logs"
  # file_path = "logs/app.log"
  retention_days = 30  # days
  colorize = true
  diagnose = true
  backtrace = true
  
[database.postgres]
  host = "127.0.0.1"
  port = 5432
  user = "your_user"
  password = "your_password"
  dbname = "your_dbname"
  
  channel_name = "task_queue"
  pool_max_size = 10
  pool_min_size = 4
```

## 示例代码

**配置类作为基础类，我一般设计成只要配置类加载有问题，就直接抛出异常中止服务。而且引入 pydantic 后，配置错误的地方也会很明确地提示出来。**

服务自身运行配置和日志配置: `pkg/config/service.py`

```python
from typing import Annotated, Literal

from pydantic import BaseModel, Field


class ServiceLogConfig(BaseModel):
    level: Annotated[Literal["DEBUG", "INFO", "WARNING", "ERROR"], Field(default="INFO", description="日志级别")]
    dir: Annotated[str, Field(default="logs", description="日志文件目录")]
    output: Annotated[Literal["STDOUT", "FILE", "BOTH"], Field(default="STDOUT", description="日志输出方式")]
    retention_days: Annotated[int, Field(default=7, gt=0, le=30, description="日志文件轮转天数")]
    colorize: Annotated[bool, Field(default=True, description="是否启用颜色日志输出")]
    backtrace: Annotated[bool, Field(default=True, description="是否启用堆栈跟踪日志输出")]
    diagnose: Annotated[bool, Field(default=True, description="是否启用诊断日志输出")]


class ServiceConfig(BaseModel):
    host: Annotated[str, Field(default="127.0.0.1", description="服务监听地址")]
    port: Annotated[int, Field(default=8080, description="服务监听端口")]
    env: Annotated[Literal["dev", "prod"], Field(default="dev", description="服务环境")]
    log: ServiceLogConfig
```

数据库配置: `pkg/config/postgres.py`

```python
from typing import Annotated
from urllib.parse import quote_plus

from pydantic import BaseModel, Field


class PostgresConfig(BaseModel):
    host: Annotated[str, Field(..., description="PostgreSQL host")]
    port: Annotated[int, Field(..., description="PostgreSQL port")]
    user: Annotated[str, Field(..., description="PostgreSQL user")]
    password: Annotated[str, Field(..., description="PostgreSQL password")]
    dbname: Annotated[str, Field(..., description="PostgreSQL database name")]
    pool_min_size: Annotated[int, Field(..., description="Minimum size of PostgreSQL connection pool")]
    pool_max_size: Annotated[int, Field(..., description="Maximum size of PostgreSQL connection pool")]

    def get_dsn(self) -> str:
        """Get PostgreSQL connection string (DSN)"""
        user = quote_plus(self.user)
        password = quote_plus(self.password)
        return f"postgresql://{user}:{password}@{self.host}:{self.port}/{self.dbname}"


class DatabaseConfig(BaseModel):
    postgres: PostgresConfig
```

组合成总的配置类：

```python
from pathlib import Path
import tomllib

from pydantic import BaseModel, ValidationError

from .service import ServiceConfig
from .postgres import DatabaseConfig


class Config(BaseModel):
    service: ServiceConfig
    database: DatabaseConfig


def get_config() -> Config:
    """Get the global configuration instance."""
    config_file = Path(__file__).parent.parent.parent / "conf" / "config.toml"

    with open(config_file, "rb") as f:
        raw_config = tomllib.load(f)

    try:
        # pydantic v2中推荐用 model_validate 实现严格校验
        return Config.model_validate(raw_config)
    except ValidationError as e:
        raise RuntimeError(f"Failed to validate config: {e}") from e

```

在`pkg/config/__init__.py`中实例化获取全局单例

```python
from .config import get_config


cfg = get_config()

__all__ = ["cfg"]
```

调用方使用配置类对象：

```python
from pkg.config import cfg

dsn = cfg.database.postgres.get_dsn()
```

## 补充

### 校验失败示例

假设我在配置文件中把 `database.postgres.port`从 `5432` 改成 `"5432qwer"`, 而模型类对该字段声明的是`int`类型，那么启动就会直接失败，错误提示如下，其中很清晰地提示了`database.postgres.port`的入参校验失败。

```
RuntimeError: Failed to validate config: 1 validation error for Config
database.postgres.port
Input should be a valid integer, unable to parse string as an integer [type=int_parsing, input_value='5432qwer', input_type=str]
For further information visit https://errors.pydantic.dev/2.13/v/int_parsing
```