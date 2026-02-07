+++
date = '2025-12-11T00:40:44+08:00'
draft = false
title = 'FastAPI - Design of tracking_id'
categories = ["program"]
tags = ["fastapi", "python"]
+++

## Introduction

In real business scenarios, tracing a request's complete processing path in logs based on a `tracking_id` is a common requirement. However, FastAPI does not provide this functionality out of the box, so developers need to implement it themselves. This article introduces how to add a tracking_id to the entire request lifecycle based on `contextvars` and automatically record it in logs.

## What is contextvars

Python 3.7 added a module `contextvars` to the standard library, which stands for "Context Variables". It is typically used to implicitly pass some environmental information variables, similar to `threading.local()`. However, `threading.local()` is thread-specific, isolating data states between threads, while `contextvars` can be used in asynchronous coroutines within the `asyncio` ecosystem. **PS: `contextvars` can not only be used in asynchronous coroutines but can also replace `threading.local()` in multi-threaded functions.**

## Basic Usage

1. First, create `context.py`

```python
import contextvars
from typing import Optional

TRACKING_ID: contextvars.ContextVar[Optional[str]] = contextvars.ContextVar(
    'tracking_id', 
    default=None
)

def get_tracking_id() -> Optional[str]:
    """Used for dependency injection"""
    return TRACKING_ID.get()
```

2. Create middleware `middlewares.py` to add tracking_id information to request and response headers. A common scenario is when customers provide a tracking_id for troubleshooting.

```python
import uuid

from starlette.middleware.base import (BaseHTTPMiddleware,
                                       RequestResponseEndpoint)
from starlette.requests import Request
from starlette.responses import Response

from context import TRACKING_ID


class TrackingIDMiddleware(BaseHTTPMiddleware):
    async def dispatch(
        self, request: Request, call_next: RequestResponseEndpoint
    ) -> Response:
        tracking_id = str(uuid.uuid4())
        token = TRACKING_ID.set(tracking_id)
        # HTTP headers conventionally use latin-1 encoding
        request.scope["headers"].append((b"x-request-id", tracking_id.encode("latin-1")))

        try:
            resp = await call_next(request)
        finally:
            # Regardless of success, reset tracking_id at the end of each request to avoid leaking to the next request
            TRACKING_ID.reset(token)

        # Optional, set tracking ID header in response
        resp.headers["X-Tracking-ID"] = tracking_id

        return resp
```

3. Write handler function `handlers.py` to test getting tracking_id in handler functions.

```python
import asyncio

from context import TRACKING_ID


async def mock_db_query():
    await asyncio.sleep(1)
    current_id = TRACKING_ID.get()
    print(f"This is mock_db_query. Current tracking ID: {current_id}")
    await asyncio.sleep(1)
```

4. Write main function `main.py`

```python
import uvicorn
from fastapi import Depends, FastAPI
from fastapi.responses import PlainTextResponse
from starlette.background import BackgroundTasks

from context import TRACKING_ID, get_tracking_id
from handlers import mock_db_query
from middlewares import TrackingIDMiddleware

app = FastAPI()

app.add_middleware(TrackingIDMiddleware)


@app.get("/qwer")
async def get_qwer():
    """Test context variable passing"""
    current_id = TRACKING_ID.get()
    print(f"This is get qwer. Current tracking ID: {current_id}")
    return PlainTextResponse(f"Current tracking ID: {current_id}")


@app.get("/asdf")
async def get_asdf(tracking_id: str = Depends(get_tracking_id)):
    """Test dependency injection"""
    print(f"This is get asdf. tracking ID: {tracking_id}")
    await mock_db_query()
    return PlainTextResponse(f"Get request, tracking ID: {tracking_id}")

if __name__ == "__main__":
    uvicorn.run("main:app", host="127.0.0.1", port=8000, workers=4)
```

5. After starting the service, test the API with curl. You can see that the tracking_id is captured in requests in the console.

```
This is get qwer. Current tracking ID: 01b0153f-4877-4ca0-ac35-ed88ab406452
INFO:     127.0.0.1:55708 - "GET /qwer HTTP/1.1" 200 OK
This is get asdf. tracking ID: 0be61d8d-11a0-4cb6-812f-51b9bfdc2639
This is mock_db_query. Current tracking ID: 0be61d8d-11a0-4cb6-812f-51b9bfdc2639
INFO:     127.0.0.1:55722 - "GET /asdf HTTP/1.1" 200 OK
```

Console output using curl

```
$ curl -i http://127.0.0.1:8000/qwer
HTTP/1.1 200 OK
date: Sat, 29 Nov 2025 06:16:46 GMT
server: uvicorn
content-length: 57
content-type: text/plain; charset=utf-8
x-tracking-id: 01b0153f-4877-4ca0-ac35-ed88ab406452

Current tracking ID: 01b0153f-4877-4ca0-ac35-ed88ab406452

===== Another request =====

$ curl -i http://127.0.0.1:8000/asdf
HTTP/1.1 200 OK
date: Sat, 29 Nov 2025 06:16:49 GMT
server: uvicorn
content-length: 62
content-type: text/plain; charset=utf-8
x-tracking-id: 0be61d8d-11a0-4cb6-812f-51b9bfdc2639

Get request, tracking ID: 0be61d8d-11a0-4cb6-812f-51b9bfdc2639
```

## Background Task APIs

FastAPI has `from starlette.background import BackgroundTasks` which allows APIs to respond directly while putting the actual process in the background for asynchronous handling. Because the middleware above resets the tracking_id upon response, background coroutine functions **may** not be able to obtain the tracking_id. Theoretically this is the case, but during local testing it was found that tracking_id could still be obtained in asynchronous coroutines, possibly due to low concurrency in the local environment. In high-concurrency production environments, it's better to decouple explicitly and pass contextvars explicitly.

1. Keep the custom middleware class unchanged.
2. Add API for background tasks

```python
from starlette.background import BackgroundTasks
from handlers import mock_backgroud_task

@app.get("/zxcv")
async def get_zxcv(tasks: BackgroundTasks):
    """Test background tasks"""
    current_id = TRACKING_ID.get()
    print(f"This is get zxcv. The current id is {current_id}")

    # Explicitly pass tracking_id
    tasks.add_task(mock_backgroud_task, current_id)

    return PlainTextResponse(f"This is get zxcv. The current id is {current_id}")
```

3. Explicit handling in background coroutine functions. When the task starts, use the passed parameter value to re-set `TRACKING_ID` in its own task execution context. When the task ends, clean up the context set by the task itself.

```python
async def mock_backgroud_task(request_tracking_id: Optional[str]):
    if request_tracking_id is None:
        request_tracking_id = str(uuid4())
        print(f"WARNING: No tracking ID found. Generate a new one: {request_tracking_id}")
    token = TRACKING_ID.set(request_tracking_id)
    try:
        # Simulate time-consuming background asynchronous task
        await asyncio.sleep(5)
        print(f"This is mock backgroud task. Current tracking ID: {request_tracking_id}")
    finally:
        # Ensure tracking ID is reset
        TRACKING_ID.reset(token)
```

4. Start the main program and test if tracking_id is consistent.

## Logging tracking_id

Previously, tracking_id was manually added to `print()`, which was somewhat cumbersome and easy to forget. Therefore, it's best to use a logger that automatically obtains `tracking_id`, greatly reducing invasive code changes.

First, we need to encapsulate a logging module. Here we use the standard library `logging`. If you prefer `loguru`, you can also try encapsulating it with `loguru` (if the production environment has frequent and strict security scans, it's recommended to use the standard library to avoid constantly upgrading third-party dependencies). If your application runs on docker or k8s with existing console log collection tools, this logging module only needs to output to the console. If the application runs on a server and needs tools like `filebeat` to read log files, you need to solve **log file size growth**, **competition issues when multiple uvicorn worker processes write to log files simultaneously**, and **blocking of asynchronous coroutines when writing log files under high concurrency**.

The following log module example solves these issues with key features:

- Automatically obtains tracking_id without manual recording.
- Logs are in JSON format, making it easy to search logs in log aggregation systems like ELK.
- Logs are output to both stdout and log files, and can be configured to output to either one.
- Log files are rotated daily, keeping the most recent 7 days of logs by default to avoid log file size growth issues.
- Main process and worker processes output to their respective log files, avoiding competition issues when writing to the same log file simultaneously.
- Logs are first output to a queue to avoid blocking asynchronous coroutines when writing files.

1. Edit file `pkg/log/log.py`. The main content is in this section. The only objects that need to be exposed externally are `setup_logger` and `close_log_queue`.

```python
import json
import logging
import os
import re
import sys
from logging.handlers import QueueHandler, QueueListener, TimedRotatingFileHandler
from multiprocessing import current_process
from pathlib import Path
from queue import Queue
from typing import Optional

from context import TRACKING_ID

_queue_listener = None
_queue_logger: Optional[Queue] = None
PATTERN_PROCESS_NAME = re.compile(r"SpawnProcess-(\d+)")


class JSONFormatter(logging.Formatter):
    """A logging formatter that outputs logs in JSON format."""
    def format(self, record: logging.LogRecord) -> str:
        log_record = {
            "@timestamp": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "name": record.name,
            # "taskName": getattr(record, "taskName", None),  # Record task name if needed
            "processName": record.processName,  # Record process name if needed
            "tracking_id": getattr(record, "tracking_id", None),
            "loc": "%s:%d" % (record.filename, record.lineno),
            "func": record.funcName,
            "message": record.getMessage(),
        }

        return json.dumps(log_record, ensure_ascii=False, default=str)


class TrackingIDFilter(logging.Filter):
    """A logging filter that adds tracking_id to log records.
    """
    def filter(self, record):
        record.tracking_id = TRACKING_ID.get()
        return True


def _setup_console_handler(level: int) -> logging.StreamHandler:
    """Setup a StreamHandler for console logging.
    
    Args:
        level (int): The logging level.
    """
    handler = logging.StreamHandler(sys.stdout)
    handler.setLevel(level)
    handler.setFormatter(JSONFormatter())
    return handler


def _setup_file_handler(
    level: int, log_path: str, rotate_days: int
) -> TimedRotatingFileHandler:
    """Setup a TimedRotatingFileHandler for logging.
    
    Args:
        level (int): The logging level.
        log_path (str): The log path.
        rotate_days (int): The number of days to keep log files.
    """
    handler = TimedRotatingFileHandler(
        filename=log_path,
        when="midnight",
        interval=1,
        backupCount=rotate_days,
        encoding="utf-8",
    )
    handler.setLevel(level)
    handler.setFormatter(JSONFormatter())
    return handler


def _setup_queue_handler(level: int, log_queue: Queue) -> QueueHandler:
    """Setup a QueueHandler for logging.
    
    Args:
        level (int): The logging level.
        log_queue (Queue): The log queue.
    """
    handler = QueueHandler(log_queue)
    handler.setLevel(level)
    return handler


def _get_spawn_process_number(name: str) -> str:
    """
    Get the spawn process number for log file naming.
    The server should be started with multiple processes using uvicorn's --workers option.
    Prevent issues caused by multiple processes writing to the same log file.

    Args:
        name (str): The name of the log file.

    Returns:
        str: The spawn process number for log file naming.
    """
    try:
        process_name = current_process().name
        pid = os.getpid()

        if process_name == "MainProcess":
            return name
        elif m := PATTERN_PROCESS_NAME.match(process_name):
            return f"{name}-sp{m.group(1)}"
        else:
            return f"{name}-{pid}"

    except:
        return f"{name}-{os.getpid()}"


def _setup_logpath(log_dir: str, name: str) -> str:
    """Setup the log path.
    
    Args:
        log_dir (str): The log directory.
        name (str): The name of the log file. Example: "app"

    Returns:
        str: The log path.
    """
    main_name = _get_spawn_process_number(name)
    log_file = f"{main_name}.log"
    log_path = Path(log_dir) / log_file

    if not log_path.parent.exists():
        try:
            log_path.parent.mkdir(parents=True, exist_ok=True)
        except Exception as e:
            raise RuntimeError(
                f"Failed to create log directory: {log_path.parent}"
            ) from e
    return str(log_path)


def _validate(level: int, enable_console: bool, enable_file: bool, rotate_days: int) -> None:
    """Validate the log configuration.
    
    Args:
        level (int): The logging level.
        enable_console (bool): Whether to enable console logging.
        enable_file (bool): Whether to enable file logging.
        rotate_days (int): The number of days to keep log files.

    Raises:
        ValueError: If the log configuration is invalid.
    """
    if not enable_console and not enable_file:
        raise ValueError("At least one of enable_console or enable_file must be True.")

    if level not in [
        logging.DEBUG,
        logging.INFO,
        logging.WARNING,
        logging.ERROR,
        logging.CRITICAL,
    ]:
        raise ValueError("Invalid logging level specified.")

    if not isinstance(rotate_days, int) or rotate_days <= 0:
        raise ValueError("rotate_days must be a positive integer.")


def setup_logger(
    name: str = "app",
    level: int = logging.DEBUG,
    enable_console: bool = True,
    enable_file: bool = True,
    log_dir: str = "logs",
    rotate_days: int = 7,
) -> logging.Logger:
    """Setup a logger with console and/or file handlers.
    
    Args:
        name (str): The name of the logger. This will be used as the log file name prefix. Defaults to "app".
        level (int): The logging level. Defaults to logging.DEBUG.
        enable_console (bool): Whether to enable console logging. Defaults to True.
        enable_file (bool): Whether to enable file logging. Defaults to True.
        log_dir (str): The log directory. Defaults to "logs".
        rotate_days (int): The number of days to keep log files. Defaults to 7.

    Returns:
        logging.Logger: The configured logger.
    """
    logger = logging.getLogger(name)

    if logger.hasHandlers():
        return logger  # Logger is already configured

    _validate(level, enable_console, enable_file, rotate_days)

    logger.setLevel(level)
    logger.propagate = False  # Prevent log messages from being propagated to the root logger

    log_path = _setup_logpath(log_dir, name)

    handlers = []

    if enable_console:
        handlers.append(_setup_console_handler(level))

    if enable_file:
        handlers.append(_setup_file_handler(level, log_path, rotate_days))

    global _queue_logger, _queue_listener
    if not _queue_logger:
        _queue_logger = Queue(-1)

    queue_handler = _setup_queue_handler(level, _queue_logger)

    if not _queue_listener:
        _queue_listener = QueueListener(
            _queue_logger, *handlers, respect_handler_level=True
        )
        _queue_listener.start()

    logger.addHandler(queue_handler)
    logger.addFilter(TrackingIDFilter())

    return logger


def close_log_queue() -> None:
    """Close the log queue and stop the listener.
    This function should be called when the application is shutting down to ensure that the log queue is closed and the listener is stopped.
    """
    global _queue_listener
    if _queue_listener:
        _queue_listener.stop()
        _queue_listener = None
```

2. Edit `pkg/log/__init__.py` to facilitate imports from other modules. I usually use this file to tell others which objects in this module are public. The `logger` object is a singleton that can be directly used by other modules without using `setup_logger` to create separate logger objects. However, some requirements involve each class object creating its own logger, so this is also provided externally (personally I don't think it's necessary).

```python
from pathlib import Path

from .log import close_log_queue, setup_logger

logger = setup_logger(
    log_dir=str(Path(__file__).parent.parent.parent / "logs"),
)

__all__ = [
    "logger",
    "setup_logger",
    "close_log_queue",
]
```

3. Call `close_log_queue` through FastAPI's lifespan

```python
from contextlib import asynccontextmanager

from pkg.log import close_log_queue

@asynccontextmanager
async def lifespan(app: FastAPI):
    try:
        yield
    finally:
        close_log_queue()
        print("Shutdown!")


app = FastAPI(lifespan=lifespan)
```

4. Change `print()` to `logger.info()` to test if `tracking_id` is automatically output in logs. Some changes are as follows:

```python
async def mock_db_query():
    await asyncio.sleep(1)
    current_id = TRACKING_ID.get()
    logger.info(f"This is mock_db_query. Current tracking ID: {current_id}")
    await asyncio.sleep(1)
```

5. Test with curl and check logs

curl command output:

```bash
$ curl -i  http://127.0.0.1:8000/asdf
HTTP/1.1 200 OK
date: Sat, 29 Nov 2025 13:07:09 GMT
content-length: 62
content-type: text/plain; charset=utf-8
x-tracking-id: 38a015f7-b0d3-41ea-a2b3-179bf608b4bb

Get request, tracking ID: 38a015f7-b0d3-41ea-a2b3-179bf608b4bb
```

Server console output:

```
{"@timestamp": "2025-11-29T21:07:09+0800", "level": "INFO", "name": "app", "processName": "SpawnProcess-3", "tracking_id": "38a015f7-b0d3-41ea-a2b3-179bf608b4bb", "loc": "main.py:39", "func": "get_asdf", "message": "This is get asdf. tracking ID: 38a015f7-b0d3-41ea-a2b3-179bf608b4bb"}
{"@timestamp": "2025-11-29T21:07:10+0800", "level": "INFO", "name": "app", "processName": "SpawnProcess-3", "tracking_id": "38a015f7-b0d3-41ea-a2b3-179bf608b4bb", "loc": "handlers.py:12", "func": "mock_db_query", "message": "This is mock_db_query. Current tracking ID: 38a015f7-b0d3-41ea-a2b3-179bf608b4bb"}
```

Log file output:

```
{"@timestamp": "2025-11-29T21:07:09+0800", "level": "INFO", "name": "app", "processName": "SpawnProcess-3", "tracking_id": "38a015f7-b0d3-41ea-a2b3-179bf608b4bb", "loc": "main.py:39", "func": "get_asdf", "message": "This is get asdf. tracking ID: 38a015f7-b0d3-41ea-a2b3-179bf608b4bb"}
{"@timestamp": "2025-11-29T21:07:10+0800", "level": "INFO", "name": "app", "processName": "SpawnProcess-3", "tracking_id": "38a015f7-b0d3-41ea-a2b3-179bf608b4bb", "loc": "handlers.py:12", "func": "mock_db_query", "message": "This is mock_db_query. Current tracking ID: 38a015f7-b0d3-41ea-a2b3-179bf608b4bb"}
```

Based on the above three outputs, it can be seen that the tracking_id remains consistent in logs and log messages.

### Supplement: Another approach to solving multi-process file writing issues

After painstakingly debugging the above logging module, I thought of another way to solve the multi-process file writing issue - let external tools handle logging while the service only outputs to the console, similar to solutions in docker and k8s runtime environments. The following is just a concept, and it seems there shouldn't be any problems. Feel free to try it if interested.

1. Remove the file writing functionality from the logging module, keeping only the console output part. Note that standard output may also block asynchronous coroutines, so the queue handler should still be retained.
2. Use `nohup` to redirect console output to a file when starting. For example: `nohup python main.py > logs/start.log 2>&1 &`
3. Configure `logrotate` for log rotation.