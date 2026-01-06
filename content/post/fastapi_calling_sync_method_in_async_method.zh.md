+++
date = '2026-01-06T16:19:44+08:00'
draft = false
title = 'FastAPI - Calling Synchronous Methods in FastAPI Asynchronous Methods'
categories = ["program"]
tags = ["fastapi", "python"]
+++

## 前言

在异步方法中直接调用同步方法会阻塞整个事件循环，导致应用在执行同步方法期间无法处理任何其他并发请求，严重影响服务的整体性能和响应能力。

为了解决这个问题，核心思路是将同步方法交给外部线程池或进程池执行，避免阻塞主事件循环。

## 方法 1：使用 asyncio.to_thread

Python 3.9 及以后版本可以使用 `asyncio.to_thread` 方法，将同步函数运行在独立的线程中，并返回一个可供 `await` 的协程对象

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

## 方法 2：直接定义同步路由

FastAPI 支持定义同步路由，FastAPI 会自动在一个外部线程池中运行该函数。不过出于代码整体设计和一致性的考虑，不建议在异步项目中混用同步路由。

## 方法 3：使用 run_in_threadpool

FastAPI 基于 Starlette，而 Starlette 提供了一个工具函数 `run_in_threadpool`，这种方式类似于 `asyncio.to_thread`，在某些老版本的 FastAPI 或特定的 contextvars 传递场景下更常用。

```python
from fastapi.concurrency import run_in_threadpool

@app.get("/method3")
async def starlette_endpoint():
    result = await run_in_threadpool(sync_task, "Starlette")
    return {"message": result}
```

## 方法 4：使用进程池

对于 CPU 密集型任务，应该使用多进程 `ProcessPoolExecutor` 来处理

```python
import concurrent.futures
import math
from fastapi import FastAPI

app = FastAPI()
# 创建一个全局进程池
executor = concurrent.futures.ProcessPoolExecutor()

def cpu_intensive_calculation(n: int):
    # 模拟重度 CPU 计算
    return sum(math.isqrt(i) for i in range(n))

@app.get("/cpu-bound-task")
async def cpu_task():
    loop = asyncio.get_running_loop()
    result = await loop.run_in_executor(executor, cpu_intensive_calculation, 10**7)
    return {"result": result}
```
