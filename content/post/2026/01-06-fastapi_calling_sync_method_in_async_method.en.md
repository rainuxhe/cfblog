+++
date = '2026-01-06T16:19:44+08:00'
draft = false
title = 'FastAPI - Calling Synchronous Methods in FastAPI Asynchronous Methods'
categories = ["program"]
tags = ["fastapi", "python"]
+++

## Introduction

Directly calling synchronous methods within asynchronous methods blocks the entire event loop, preventing the application from handling any other concurrent requests while executing the synchronous method. This severely impacts the overall performance and responsiveness of the service.

To address this issue, the core approach is to delegate synchronous methods to external thread pools or process pools for execution, thereby avoiding blocking the main event loop.

## Method 1: Using asyncio.to_thread

Python 3.9 and later versions provide the `asyncio.to_thread` method, which runs synchronous functions in a separate thread and returns a coroutine object that can be awaited.

```python
import asyncio
import time
from fastapi import FastAPI

app = FastAPI()

def sync_task(name: str):
    time.sleep(2) 
    return f"Hello {name}, sync task done!"

@app.get("/async-call")
async def async_endpoint():
    result = await asyncio.to_thread(sync_task, "World")
    
    return {"message": result}
```

## Method 2: Defining Synchronous Routes Directly

FastAPI supports defining synchronous routes, and FastAPI will automatically run the function in an external thread pool. However, for the sake of overall code design and consistency, mixing synchronous routes in asynchronous projects is not recommended.

## Method 3: Using run_in_threadpool

FastAPI is built on top of Starlette, which provides a utility function called `run_in_threadpool`. This approach is similar to `asyncio.to_thread` and is more commonly used in older versions of FastAPI or specific contextvars propagation scenarios.

```python
from fastapi.concurrency import run_in_threadpool

@app.get("/method3")
async def starlette_endpoint():
    result = await run_in_threadpool(sync_task, "Starlette")
    return {"message": result}
```

## Method 4: Using Process Pools

For CPU-intensive tasks, multiprocessing with `ProcessPoolExecutor` should be used for handling.

```python
import concurrent.futures
import math
from fastapi import FastAPI

app = FastAPI()
# Create a global process pool
executor = concurrent.futures.ProcessPoolExecutor()

def cpu_intensive_calculation(n: int):
    # Simulate intensive CPU computation
    return sum(math.isqrt(i) for i in range(n))

@app.get("/cpu-bound-task")
async def cpu_task():
    loop = asyncio.get_running_loop()
    result = await loop.run_in_executor(executor, cpu_intensive_calculation, 10**7)
    return {"result": result}
```

