+++
date = '2026-06-29T23:18:44+08:00'
draft = false
title = 'Validating Config Files with Pydantic'
description = 'Using Pydantic for parameter validation in config file-based configuration classes'
summary = 'Validate config file parameters with Pydantic'
isCJKLanguage = false
categories = [
    "program"
]
tags = [
    "python",
    "AI-Translated"
]
keywords = ["pydantic", "python"]
slug = 'pydantic-validate-config-file'
+++

## Introduction

Many new projects use environment variables for configuration, especially those deployed on Kubernetes — ConfigMap or Secrets are injected directly into pod environment variables, and `pydantic-settings` is used for parameter validation, which is very convenient. However, `pydantic-settings` prioritizes environment variables. For larger projects with potentially hundreds of configuration items, I still prefer using config files, where related configurations can be nested for easier management.

Previously, when writing file-based configuration classes, I would create various `Mixin` classes with validation logic inside getter methods, then assemble them into a `Config` class. It worked well enough after getting used to it — until today, when I was adding a new set of configuration options and suddenly realized: wait, since the project (based on FastAPI) already includes Pydantic, why not just use Pydantic for parameter validation directly?!

This article uses `TOML` format config files as an example (the config file is loaded into a dict and passed to Pydantic; JSON and YAML work similarly), paired with `Pydantic` to implement a configuration class with parameter validation.

## Installation

Only `pydantic` is needed, no need for `pydantic-settings`. Python 3.11+ includes `tomllib` in the standard library for parsing TOML files.

```shell
uv add -U pydantic
# python -m pip install -U pydantic
```

## Example Config File

Below is a partial config file. Real projects would certainly have more configuration items:

```toml
[service]
  host = "127.0.0.1"
  port = 8000
  env = "dev"  # dev, prod

[service.log]
  level = "DEBUG"  # DEBUG, INFO, WARNING, ERROR
  output = "BOTH"  # STDOUT, FILE, BOTH
  dir = "logs"
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

## Example Code

**I typically design the configuration class so that if loading fails, it throws an exception and stops the service. With Pydantic, any misconfiguration is clearly indicated.**

Service runtime config and log config: `pkg/config/service.py`

```python
from typing import Annotated, Literal

from pydantic import BaseModel, Field


class ServiceLogConfig(BaseModel):
    level: Annotated[Literal["DEBUG", "INFO", "WARNING", "ERROR"], Field(default="INFO", description="Log level")]
    dir: Annotated[str, Field(default="logs", description="Log file directory")]
    output: Annotated[Literal["STDOUT", "FILE", "BOTH"], Field(default="STDOUT", description="Log output method")]
    retention_days: Annotated[int, Field(default=7, gt=0, le=30, description="Log file retention days")]
    colorize: Annotated[bool, Field(default=True, description="Enable colored log output")]
    backtrace: Annotated[bool, Field(default=True, description="Enable stack trace log output")]
    diagnose: Annotated[bool, Field(default=True, description="Enable diagnostic log output")]


class ServiceConfig(BaseModel):
    host: Annotated[str, Field(default="127.0.0.1", description="Service listen address")]
    port: Annotated[int, Field(default=8080, description="Service listen port")]
    env: Annotated[Literal["dev", "prod"], Field(default="dev", description="Service environment")]
    log: ServiceLogConfig
```

Database config: `pkg/config/postgres.py`

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

Combined into the top-level config class:

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
        return Config.model_validate(raw_config)
    except ValidationError as e:
        raise RuntimeError(f"Failed to validate config: {e}") from e

```

Instantiate as a global singleton in `pkg/config/__init__.py`:

```python
from .config import get_config

cfg = get_config()

__all__ = ["cfg"]
```

Usage:

```python
from pkg.config import cfg

dsn = cfg.database.postgres.get_dsn()
```

## Additional Notes

### Validation Failure Example

Suppose I change `database.postgres.port` from `5432` to `"5432qwer"` in the config file, while the model declares it as `int`. The application will fail to start immediately, with a clear error message indicating which field failed validation:

```
RuntimeError: Failed to validate config: 1 validation error for Config
database.postgres.port
Input should be a valid integer, unable to parse string as an integer [type=int_parsing, input_value='5432qwer', input_type=str]
For further information visit https://errors.pydantic.dev/2.13/v/int_parsing
```
