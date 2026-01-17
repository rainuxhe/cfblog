+++
date = '2026-01-17T17:36:52+08:00'
draft = false
title = 'Flask - Design and Implementation of tracking_id'
description = "This article details how to implement request tracking ID (tracking_id) functionality in Flask applications, including middleware design, logging, response formatting, and a complete solution to help developers achieve request tracing and enhance system observability."
categories = ["program"]
tags = ["flask", "python"]
keywords = [
    "flask",
    "python",
    "X-Tracking-ID",
    "tracking_id",
]
+++

## Introduction

In actual business scenarios, tracing the complete processing path of a request based on `tracking_id` is a common requirement. With the help of Flask's built-in global object `g` and hook functions, it's easy to add a `tracking_id` to each request and automatically log it.

Main topics:

- How to add `tracking_id` to each request
- How to automatically log `tracking_id`
- How to customize response classes, implement unified response formats, and add `tracking_id` to response headers
- View function unit testing examples
- Gunicorn configuration

## Project Structure

Although it appears complex, the implementation of tracking_id is actually quite simple. This article organizes the code according to production project standards, adding Gunicorn configuration and unit testing code, as well as standardizing log formats and JSON response formats.

```
├── apis
│   ├── common
│   │   ├── common.py
│   │   └── __init__.py
│   └── __init__.py
├── gunicorn.conf.py
├── handles
│   └── user.py
├── logs
│   ├── access.log
│   └── error.log
├── main.py
├── middlewares
│   ├── __init__.py
│   └── tracking_id.py
├── pkgs
│   └── log
│       ├── app_log.py
│       └── __init__.py
├── pyproject.toml
├── pytest.ini
├── README.md
├── responses
│   ├── __init__.py
│   └── json_response.py
├── tests
│   └── apis
│       └── test_common.py
├── tmp
│   └── gunicorn.pid
└── uv.lock
```

Install dependencies

```shell
uv add flask
uv add gunicorn gevent  # Usually required for production deployment
uv add --dev pytest           # Testing library
```

## Implementing the tracking_id Middleware

Code file: `middlewares/tracking_id.py`

```python
from uuid import uuid4

from flask import Flask, Response, g, request


def tracking_id_middleware(app: Flask):
    """
    Tracking ID middleware
    Generate or retrieve tracking ID for each request to trace request flows
    """
    
    @app.before_request
    def tracking_id_before_request():
        """
        Pre-request handler
        Check if X-Tracking-ID header exists, generate a new UUID as tracking ID if not present
        Store the tracking ID in Flask's global object g for subsequent processing
        """
        # Get X-Tracking-ID from request headers
        tracking_id = request.headers.get("X-Tracking-ID")
        if not tracking_id:
            # Generate a new UUID if X-Tracking-ID is not present in headers
            tracking_id = str(uuid4())
        # Store tracking ID in Flask's global object g for subsequent processing
        g.tracking_id = tracking_id

    @app.after_request
    def tracking_id_after_request(response: Response):
        """
        Post-request handler
        Add tracking ID to response headers so clients know the tracking ID for this request
        """
        # Check if X-Tracking-ID already exists in response headers
        tracking_id = response.headers.get("X-Tracking-ID", "")
        if not tracking_id:
            # Get from global object g if X-Tracking-ID is not in response headers
            tracking_id = g.get("tracking_id", "")
            # Add tracking ID to response headers
            response.headers["X-Tracking-ID"] = tracking_id
        return response

    # Return app instance
    return app
```

Code file `middlewares/__init__.py`, for easier imports in other modules

```python
from .tracking_id import tracking_id_middleware

__all__ = [
    "tracking_id_middleware",
]
```

## Logging Module - Automatically Record tracking_id

Implement a simple console logging module with JSON format logs that automatically add tracking_id to logs, eliminating the need to manually pass `tracking_id` to methods like `logger.info()`.

Code file `pkgs/log/app_log.py`

```python
import json
import logging
import sys

from flask import g


class JSONFormatter(logging.Formatter):
    """Log formatter that outputs logs in JSON format."""

    def format(self, record: logging.LogRecord) -> str:
        log_record = {
            "@timestamp": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "name": record.name,
            # "processName": record.processName,  # Uncomment if process name is needed
            "tracking_id": getattr(record, "tracking_id", None),
            "loc": "%s:%d" % (record.filename, record.lineno),
            "func": record.funcName,
            "message": record.getMessage(),
        }

        return json.dumps(log_record, ensure_ascii=False, default=str)


class TrackingIDFilter(logging.Filter):
    """Log filter that adds tracking_id to log records."""

    def filter(self, record):
        record.tracking_id = g.get("tracking_id", None)
        return True


def _setup_console_handler(level: int) -> logging.StreamHandler:
    """Set up StreamHandler for console logging.

    Args:
        level (int): The logging level.
    """
    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(level)
    handler.setFormatter(JSONFormatter())
    return handler


def setup_app_logger(level: int = logging.INFO, name: str = "app") -> logging.Logger:
    logger = logging.getLogger(name)

    if logger.hasHandlers():
        return logger

    logger.setLevel(level)
    logger.propagate = False

    logger.addHandler(_setup_console_handler(level))
    logger.addFilter(TrackingIDFilter())

    return logger
```

Initialize `logger` in `pkgs/log/__init__.py` for singleton access.

```python
from .app_log import setup_app_logger

logger = setup_app_logger()

__all__ = ["logger"]
```

## Custom Response Classes

Standardize JSON response formats and add `X-Tracking-ID` and `X-DateTime` to response headers.

Code file `responses/json_response.py`

```python
import json
from datetime import datetime
from http import HTTPStatus
from typing import Any

from flask import Response, g, request


class JsonResponse(Response):
    def __init__(
        self,
        data: Any = None,
        code: HTTPStatus = HTTPStatus.OK,
        msg: str = "this is a json response",
    ):
        x_tracking_id = g.get("tracking_id", "")
        x_datetime = datetime.now().astimezone().isoformat(timespec="seconds")
        resp_headers = {
            "Content-Type": "application/json",
            "X-Tracking-ID": x_tracking_id,
            "X-DateTime": x_datetime,
        }
        try:
            resp = json.dumps(
                {
                    "code": code.value,
                    "msg": msg,
                    "data": data,
                },
                ensure_ascii=False,
                default=str,
            )
        except Exception as e:
            resp = json.dumps(
                {
                    "code": HTTPStatus.INTERNAL_SERVER_ERROR.value,
                    "msg": f"Response serialization error: {str(e)}",
                    "data": None,
                }
            )
        super().__init__(response=resp, status=code.value, headers=resp_headers)


class Success(JsonResponse):
    def __init__(self, data: Any = None, msg: str = ""):
        if not msg:
            msg = f"{request.method} {request.path} success"
        super().__init__(data=data, code=HTTPStatus.OK, msg=msg)


class Fail(JsonResponse):
    def __init__(self, msg: str = "", data: Any = None):
        if not msg:
            msg = f"{request.method} {request.path} failed"
        super().__init__(data=data, code=HTTPStatus.INTERNAL_SERVER_ERROR, msg=msg)


class ArgumentNotFound(JsonResponse):
    def __init__(self, msg: str = "", data: Any = None):
        if not msg:
            msg = f"{request.method} {request.path} argument not found"
        super().__init__(data=data, code=HTTPStatus.BAD_REQUEST, msg=msg)


class ArgumentInvalid(JsonResponse):
    def __init__(self, msg: str = "", data: Any = None):
        if not msg:
            msg = f"{request.method} {request.path} argument invalid"
        super().__init__(data=data, code=HTTPStatus.BAD_REQUEST, msg=msg)


class AuthFailed(JsonResponse):
    """HTTP status code: 401"""

    def __init__(self, msg: str = "", data: Any = None):
        if not msg:
            msg = f"{request.method} {request.path} auth failed"
        super().__init__(data=data, code=HTTPStatus.UNAUTHORIZED, msg=msg)


class ResourceConflict(JsonResponse):
    """HTTP status code: 409"""

    def __init__(self, msg: str = "", data: Any = None):
        if not msg:
            msg = f"{request.method} {request.path} resource conflict"
        super().__init__(data=data, code=HTTPStatus.CONFLICT, msg=msg)


class ResourceNotFound(JsonResponse):
    """HTTP status code: 404"""

    def __init__(self, msg: str = "", data: Any = None):
        if not msg:
            msg = f"{request.method} {request.path} resource not found"
        super().__init__(data=data, code=HTTPStatus.NOT_FOUND, msg=msg)


class ResourceForbidden(JsonResponse):
    """HTTP status code: 403"""

    def __init__(self, msg: str = "", data: Any = None):
        if not msg:
            msg = f"{request.method} {request.path} resource forbidden"
        super().__init__(data=data, code=HTTPStatus.FORBIDDEN, msg=msg)

```

Code file `responses/__init__.py`, for easier access in other modules.

```python
from .json_response import (
    ArgumentInvalid,
    ArgumentNotFound,
    AuthFailed,
    Fail,
    JsonResponse,
    ResourceConflict,
    ResourceForbidden,
    ResourceNotFound,
    Success,
)

__all__ = [
    "JsonResponse",
    "Success",
    "Fail",
    "ArgumentNotFound",
    "ArgumentInvalid",
    "AuthFailed",
    "ResourceConflict",
    "ResourceNotFound",
    "ResourceForbidden",
]
```

## Writing View Functions

Code file `apis/common/common.py`. The following defines 5 routes, mainly used to test whether response classes return JSON format correctly.

```python
from datetime import datetime

from flask import Blueprint

from handles import user as user_handle
from pkgs.log import logger
from responses import Success

route = Blueprint("common_apis", __name__, url_prefix="/api")


@route.get("/health")
def health_check():
    # print(g.get("tracking_id", "no-tracking-id"))
    logger.info("Health check")
    return Success(data="OK")


@route.get("/users")
def get_users():
    users = user_handle.get_users()
    return Success(data=users)


@route.get("/names")
def get_names():
    names = ["Alice", "Bob", "Charlie"]
    return Success(data=names)


@route.get("/item")
def get_item():
    item = {"id": 101, "name": "Sample Item", "price": 29.99, "now": datetime.now()}
    return Success(data=item)


@route.get("/error")
def get_error():
    raise Exception("This is a test exception")

```

The `GET /api/users` route calls code in `handles/`, simulating database queries. The code in `handles/user.py` is as follows:

```python
import time
from typing import Any, Dict, List


def get_users() -> List[Dict[str, Any]]:
    # Simulate fetching user data
    time.sleep(0.1)  # Simulate delay
    users = [{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}]
    return users
```

Code file `apis/common/__init__.py` imports blueprints and exposes them uniformly. Since the example code defines only one blueprint, this section is kept simple. If there are multiple blueprints, they can be added to a list and registered in the Flask app in one iteration.

```python
from .common import route
# from .common import route as common_route

# routes = [
#     common_route,
# ]

__all__ = ["route"]
```

Code file `apis/__init__.py` provides a factory function for Flask apps.

```python
import traceback

from flask import Flask

from apis.common import route as common_route
from middlewares import tracking_id_middleware
from responses import Fail, ResourceNotFound
from pkgs.log import logger



# Error handlers
def error_handler_notfound(error):
    return ResourceNotFound()


def error_handler_generic(error):
    logger.error(traceback.format_exc())
    return Fail(data=str(error))



def create_app() -> Flask:
    app = Flask(__name__)

    # Register middleware
    app = tracking_id_middleware(app)

    # Register error handlers
    app.errorhandler(Exception)(error_handler_generic)
    app.errorhandler(404)(error_handler_notfound)

    # Register blueprints
    app.register_blueprint(common_route)

    return app

__all__ = [
    "create_app",
]
```

Entry code file `main.py`

```python
from apis import create_app

app = create_app()

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8000, debug=False)
```

## Simple Run Tests

1. Start the application

```bash
# Method 1, direct start, for simple testing
python main.py

# Method 2, using gunicorn, production deployment method. Config file default path is ./gunicorn.conf.py
gunicorn main:app
```

2. curl request `/api/health`. You can see that `X-Tracking-ID` and `X-DateTime` are already in the response headers

```bash
$ curl -v http://127.0.0.1:8000/api/health
*   Trying 127.0.0.1:8000...
* Connected to 127.0.0.1 (127.0.0.1) port 8000
* using HTTP/1.x
> GET /api/health HTTP/1.1
> Host: 127.0.0.1:8000
> User-Agent: curl/8.14.1
> Accept: */*
>
* Request completely sent off
< HTTP/1.1 200 OK
< Server: gunicorn
< Date: Sat, 17 Jan 2026 08:41:07 GMT
< Connection: keep-alive
< Content-Type: application/json
< X-Tracking-ID: 1f0adb8d-9bee-49d4-873f-31aa1437da60
< X-DateTime: 2026-01-17T16:41:07+08:00
< Content-Length: 61
<
* Connection #0 to host 127.0.0.1 left intact
{"code": 200, "msg": "GET /api/health success", "data": "OK"}
```

3. curl request `/api/users`. Manually specify `X-Tracking-ID` in the request headers, and the response will maintain the same ID.

```bash
$ curl -v http://127.0.0.1:8000/api/users -H 'X-Tracking-ID:123456'
*   Trying 127.0.0.1:8000...
* Connected to 127.0.0.1 (127.0.0.1) port 8000
* using HTTP/1.x
> GET /api/users HTTP/1.1
> Host: 127.0.0.1:8000
> User-Agent: curl/8.14.1
> Accept: */*
> X-Tracking-ID:123456
>
* Request completely sent off
< HTTP/1.1 200 OK
< Server: gunicorn
< Date: Sat, 17 Jan 2026 08:44:37 GMT
< Connection: keep-alive
< Content-Type: application/json
< X-Tracking-ID: 123456
< X-DateTime: 2026-01-17T16:44:37+08:00
< Content-Length: 110
<
* Connection #0 to host 127.0.0.1 left intact
{"code": 200, "msg": "GET /api/users success", "data": [{"id": 1, "name": "Alice"}, {"id": 2, "name": "Bob"}]}
```

## Writing Unit Tests

Use pytest for unit testing. This is just a simple example.

### Configure pytest

Configuration file `pytest.ini`

```ini
[pytest]
testpaths = "tests"
pythonpath = "."
```

### Test code

Code file `tests/apis/test_common.py`

```python
from typing import Generator
from unittest.mock import MagicMock, patch

import pytest
from flask import Flask
from flask.testing import FlaskClient

from apis.common import route as common_route


@pytest.fixture
def app() -> Generator[Flask, None, None]:
    app = Flask(__name__)
    app.config.update(
        {
            "TESTING": True,
            "DEBUG": False,
        }
    )
    app.register_blueprint(common_route)
    yield app


@pytest.fixture
def client(app: Flask) -> FlaskClient:
    return app.test_client()


class TestGetHealth:
    def test_get_health_success(self, client: FlaskClient) -> None:
        resp = client.get("/api/health")
        assert resp.status_code == 200

        resp_headers = resp.headers
        assert resp_headers.get("Content-Type") == "application/json"
        assert "X-Tracking-ID" in resp_headers
        assert "X-DateTime" in resp_headers

        resp_body = resp.json
        assert resp_body == {
            "code": 200,
            "msg": "GET /api/health success",
            "data": "OK",
        }


class TestGetUsers:
    @patch("apis.common.common.user_handle.get_users")
    def test_get_users(self, mock_get_users: MagicMock, client: FlaskClient) -> None:
        # Mock user.get_users() return value
        mock_get_users.return_value = [
            {"id": 1, "name": "Alice123"},
            {"id": 2, "name": "Bob456"},
        ]

        # Send request
        resp = client.get("/api/users")
        assert resp.status_code == 200

        resp_headers = resp.headers
        assert resp_headers.get("Content-Type") == "application/json"
        assert "X-Tracking-ID" in resp_headers
        assert "X-DateTime" in resp_headers

        # resp_body = resp.json

        mock_get_users.assert_called_once()

```

### Execute tests

```shell
pytest -vv
```

## Configure Gunicorn

Code file `gunicorn.conf.py`. Simply configure some startup parameters and request log formats.

```python
# Gunicorn configuration file
from pathlib import Path
from multiprocessing import cpu_count
import gunicorn.glogging
from datetime import datetime

class CustomLogger(gunicorn.glogging.Logger):
    def atoms(self, resp, req, environ, request_time):
        """
        Override atoms method to customize log placeholders
        """
        # Get default placeholder data
        atoms = super().atoms(resp, req, environ, request_time)
        
        # Customize 't' (timestamp) format
        now = datetime.now().astimezone()
        atoms['t'] = now.isoformat(timespec="seconds")
        
        return atoms
    

# Preload application code
preload_app = True

# Number of worker processes: usually 2 times CPU cores plus 1
# workers = int(cpu_count() * 2 + 1)
workers = 2

# Use gevent async worker type, suitable for I/O intensive applications
# Note: gevent worker doesn't use threads parameter, instead uses coroutines for concurrent processing
worker_class = "gevent"

# Maximum concurrent connections per gevent worker
worker_connections = 2000

# Bind address and port
bind = "127.0.0.1:8000"

# Process name
proc_name = "flask-dev"

# PID file path
pidfile = str(Path(__file__).parent / "tmp" / "gunicorn.pid")

logger_class = CustomLogger
access_log_format = (
    '{"@timestamp": "%(t)s", '
    '"remote_addr": "%(h)s", '
    '"protocol": "%(H)s", '
    '"host": "%({host}i)s", '
    '"request_method": "%(m)s", '
    '"request_path": "%(U)s", '
    '"status_code": %(s)s, '
    '"response_length": %(b)s, '
    '"referer": "%(f)s", '
    '"user_agent": "%(a)s", '
    '"x_tracking_id": "%({x-tracking-id}i)s", '
    '"request_time": %(L)s}'
)

# Access log path
accesslog = str(Path(__file__).parent / "logs" / "access.log")

# Error log path
errorlog = str(Path(__file__).parent / "logs" / "error.log")

# Log level
loglevel = "debug"
```

Output log format. You can see the log format complies with JSON specification, making it easier for FileBeat to collect and for searching in Kibana.

```shell
$ tail -n 1 logs/access.log | python3 -m json.tool
{
    "@timestamp": "2026-01-17T16:44:37+08:00",
    "remote_addr": "127.0.0.1",
    "protocol": "HTTP/1.1",
    "host": "127.0.0.1:8000",
    "request_method": "GET",
    "request_path": "/api/users",
    "status_code": 200,
    "response_length": 110,
    "referer": "-",
    "user_agent": "curl/8.14.1",
    "x_tracking_id": "123456",
    "request_time": 0.102042
}
```

## Notes

### Important Notes about Global Object g

1. `g` is not a process or thread-shared global variable; use `g` only within request processing flows.
2. If a background thread or async task is started in a view function, accessing `g` directly in the sub-thread will usually cause errors or fail to retrieve data. In this case, explicitly pass the data.
3. Do not store large files or data objects in `g`, as this will consume excessive memory.
4. `g` is not `session`.