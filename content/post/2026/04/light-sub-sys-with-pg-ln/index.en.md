+++
date = '2026-04-07T00:24:04+08:00'
draft = false
title = 'Building a Lightweight Subscription System with Postgres Listen/Notify'
description = 'Building a Lightweight Subscription System with Postgres Listen/Notify'
summary = 'Build a lightweight message subscription system with Postgres Listen/Notify'
isCJKLanguage = false
categories = ["program"]
tags = ["postgres", "python", "AI-Translated"]
keywords = ["postgres", "python"]
slug = 'light-sub-sys-with-pg-ln'
+++

## Overview

When designing the message module and caching module for an internal system, we only had a Postgres dependency. Considering the small user base, there was no need to add Redis and increase operational burden. Caching was easy — just use an UNLOGGED table. While pondering how to implement messaging with database tables, I discovered that PostgreSQL provides built-in commands `LISTEN` and `NOTIFY` for asynchronous communication between the database server and connected clients. This PostgreSQL-specific extension allows the database to function as a lightweight message queue (MQ) system, enabling applications to generate events from the database and have other clients respond in real time. It was a perfect fit, so I decided to give it a try.

### Core Features

- **Lightweight Implementation**: No additional message middleware required, directly leveraging PostgreSQL's built-in functionality
- **Asynchronous Communication**: Supports publish-subscribe pattern for decoupled component communication
- **Memory Efficient**: Channels are pure in-memory objects, consuming no disk space

## Environment and Version

- **Python**: 3.12+
- **PostgreSQL**: 14+
- **psycopg**: 3.3+

## Core Concepts of LISTEN/NOTIFY

### Basic Usage

```sql
-- Subscriber: listen on a channel
LISTEN my_channel;

-- Publisher: send a notification
NOTIFY my_channel, 'Hello, World!';
```

### Viewing Channels and Monitoring

```sql
-- View currently listening channels
SELECT pg_listening_channels();

-- View system notification status
SELECT * FROM pg_stat_activity WHERE backend_type = 'client backend';
```

### Dynamic Message Generation

The standard `NOTIFY` command requires messages to be explicitly specified and doesn't support dynamic string concatenation. However, you can use the `pg_notify()` function to generate dynamic notifications:

```sql
-- Use pg_notify function for dynamic messages
SELECT pg_notify('my_channel', 'Hello, ' || 'World!');

-- Dynamic message with parameters
SELECT pg_notify('audit_channel', 'User ' || current_user || ' logged in at ' || now()::text);
```

## Python Implementation

### Project Structure

```
├── main.py              # Core: TaskWorker and TaskProducer
├── conf/
│   └── config.toml     # Config file
└── pkg/
    └── config/         # Config management module
```

### Installing Dependencies

```shell
uv add "psycopg[binary,pool]>=3.3.3"
```

### Config Management

Manage database connection and channel settings via a config file:

```toml
# conf/config.toml
[database.postgres]
host = "127.0.0.1"
port = 5432
user = "username"
password = "password"
dbname = "database_name"
pool_min_size = 2
pool_max_size = 10
channel = "task_channel"
```

Config module code: `pkg/config/config.py`

```python
import tomllib
from typing import Any, Dict


class BaseConfig:
    def __init__(self, cfg_file: str):
        self._cfg_file = cfg_file
        self._data: Dict[str, Any] = {}
        self._load_config()

    def _load_config(self) -> None:
        if self._data:
            return

        try:
            with open(self._cfg_file, "rb") as f:
                self._data = tomllib.load(f)
        except FileNotFoundError:
            raise RuntimeError(f"Config file not found: {self._cfg_file}")
        except Exception as e:
            raise RuntimeError(f"Failed to load config file: {e}") from e


class PostgresConfigMixin(BaseConfig):
    def postgres_host(self) -> str:
        return self._data.get("database", {}).get("postgres", {}).get("host", "")

    def postgres_port(self) -> int:
        return self._data.get("database", {}).get("postgres", {}).get("port", 5432)

    def postgres_user(self) -> str:
        return self._data.get("database", {}).get("postgres", {}).get("user", "")

    def postgres_password(self) -> str:
        return self._data.get("database", {}).get("postgres", {}).get("password", "")

    def postgres_dbname(self) -> str:
        return self._data.get("database", {}).get("postgres", {}).get("dbname", "")

    def postgres_pool_min_size(self) -> int:
        return self._data.get("database", {}).get("postgres", {}).get("pool_min_size", 2)

    def postgres_pool_max_size(self) -> int:
        return self._data.get("database", {}).get("postgres", {}).get("pool_max_size", 10)

    def postgres_channel(self) -> str:
        return self._data.get("database", {}).get("postgres", {}).get("channel", "default_channel")

    def get_postgres_dsn(self, hide_password: bool = False) -> str:
        password = self.postgres_password()
        if hide_password and password:
            password = "***"
        return (
            f"postgresql://{self.postgres_user()}:{password}@"
            f"{self.postgres_host()}:{self.postgres_port()}/{self.postgres_dbname()}"
        )


class LLMConfigMixin(BaseConfig):
    """LLM config mixin"""

    def llm_model(self) -> str:
        return self._data.get("llm", {}).get("model", "")

    def llm_base_url(self) -> str:
        return self._data.get("llm", {}).get("base_url", "")

    def llm_api_key(self) -> str:
        return self._data.get("llm", {}).get("api_key", "")


class Config(PostgresConfigMixin, LLMConfigMixin):
    def __init__(self, cfg_file: str = "conf/config.toml"):
        super().__init__(cfg_file)

    def reload(self) -> None:
        self._data = {}
        self._load_config()

```

### Core Component Implementation

#### 1. Task Consumer (TaskWorker)

`TaskWorker` listens on a specified channel and processes received tasks:

```python
# main.py - TaskWorker class core
import asyncio
import json
import signal
from typing import Set

from psycopg import AsyncConnection, Notify, sql
from psycopg_pool import AsyncConnectionPool

from pkg.config import cfg

MAX_CONCURRENCY = 10


class TaskWorker:
    def __init__(self, dsn: str, channel: str):
        self._dsn = dsn
        self.channel = channel
        self.pool: AsyncConnectionPool | None = None
        self.listener_conn: AsyncConnection | None = None
        self.sem = asyncio.Semaphore(MAX_CONCURRENCY)
        self.active_tasks: Set[asyncio.Task] = set()

    async def start(self) -> None:
        self.pool = AsyncConnectionPool(
            self._dsn,
            min_size=cfg.postgres_pool_min_size(),
            max_size=cfg.postgres_pool_max_size(),
            open=False,
        )
        await self.pool.open()

        self.listener_conn = await AsyncConnection.connect(self._dsn, autocommit=True)
        await self.listener_conn.execute(
            sql.SQL("LISTEN {}").format(sql.Identifier(self.channel))
        )
        print(f"Listening on channel: {self.channel}")

        try:
            async for notify in self.listener_conn.notifies():
                if notify.channel == self.channel and notify.payload:
                    await self._dispatch_task(notify)
        except asyncio.CancelledError:
            print("Listener cancelled")
        except Exception as e:
            print(f"Listener error: {e}")
        finally:
            await self.stop()

    async def _dispatch_task(self, notify: Notify) -> None:
        task_info = notify.payload.strip()
        try:
            task_data = json.loads(task_info)
            print(f"Received task notification: {task_data}")
        except json.JSONDecodeError:
            task_data = {"task_id": task_info}
            print(f"Received non-JSON task notification: {task_data}")
        except Exception as e:
            print(f"Invalid task ID received: {task_info}")
            return

        if not isinstance(task_data, dict) or "task_id" not in task_data:
            print(f"Missing task_id in notification: {task_data}")
            return

        task = asyncio.create_task(self._process_task(task_data))
        self.active_tasks.add(task)
        task.add_done_callback(self.active_tasks.discard)

    async def _process_task(self, task_data: dict) -> None:
        if not self.pool:
            raise RuntimeError("Connection pool is not initialized")
        async with self.sem:
            async with self.pool.connection() as conn:
                try:
                    await self._execute_business(task_data)
                    print(f"<= Task {task_data['task_id']} completed successfully")
                except Exception as e:
                    print(f"Error processing task {task_data['task_id']}: {e}")
                    await self._log_failure(conn, task_data["task_id"], str(e))

    async def _execute_business(self, task_data: dict) -> None:
        print(f"<= Processing task {task_data}...")
        await asyncio.sleep(5)
        print(f"<= Task {task_data} done.")

    async def _log_failure(self, conn: AsyncConnection, task_id: int, error_msg: str):
        try:
            print(f"Logging failure for task {task_id}: {error_msg}")
        except Exception as e:
            print(f"Failed to log error for task {task_id}: {e}")

    async def stop(self) -> None:
        print("Stopping TaskWorker...")
        if self.active_tasks:
            await asyncio.gather(*self.active_tasks, return_exceptions=True)

        if self.listener_conn:
            await self.listener_conn.close()

        if self.pool:
            await self.pool.close()

        print("TaskWorker stopped gracefully.")
```

#### 2. Task Publisher (TaskPublisher)

`TaskPublisher` publishes task messages to a channel:

```python
# main.py - TaskPublisher class
class TaskPublisher:
    def __init__(self, dsn: str):
        self._dsn = dsn
        self._pool: AsyncConnectionPool | None = None

    async def start(self):
        if not self._pool:
            self._pool = AsyncConnectionPool(
                self._dsn,
                min_size=cfg.postgres_pool_min_size(),
                max_size=cfg.postgres_pool_max_size(),
                open=False,
            )
            await self._pool.open()
        print("TaskPublisher started.")

    async def publish(self, channel: str, payload: dict):
        if not self._pool:
            raise RuntimeError("Connection pool is not initialized")

        async with self._pool.connection() as conn:
            try:
                payload_str = json.dumps(payload, default=str)
                await conn.execute(
                    sql.SQL("NOTIFY {}, {}").format(
                        sql.Identifier(channel), sql.Literal(payload_str)
                    )
                )
                print(f"=> Published task to channel {channel}: {payload_str}")
                return True
            except Exception as e:
                print(f"Failed to publish task to channel {channel}: {e}")
                return False

    async def publish_batch(self, channel: str, payloads: list[dict]):
        if not self._pool:
            raise RuntimeError("Connection pool is not initialized")

        count = 0
        async with self._pool.connection() as conn:
            for payload in payloads:
                try:
                    payload_str = json.dumps(payload, default=str)
                    await conn.execute(
                        sql.SQL("NOTIFY {}, {}").format(
                            sql.Identifier(channel), sql.Literal(payload_str)
                        )
                    )
                    print(f"=> Published task to channel {channel}: {payload_str}")
                    count += 1
                except Exception as e:
                    print(f"Failed to publish batch tasks to channel {channel}: {e}")
        return count

    async def stop(self):
        if self._pool:
            await self._pool.close()
        print("TaskPublisher stopped.")

    async def __aenter__(self):
        await self.start()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb):
        await self.stop()
```

### Demo

```python
# main.py
async def run_worker():
    worker = TaskWorker(cfg.get_postgres_dsn(), cfg.postgres_channel())
    task = asyncio.create_task(worker.start())
    return task


async def run_publisher():
    async with TaskPublisher(cfg.get_postgres_dsn()) as publisher:
        for i in range(1, 11):
            payload = {"task_id": i, "data": f"Task data {i}"}
            await publisher.publish(cfg.postgres_channel(), payload)
            await asyncio.sleep(0.5)


async def main():
    worker_task = await run_worker()
    await asyncio.sleep(2)

    await run_publisher()
    print("All tasks published successfully.")

    await asyncio.sleep(30)

    worker_task.cancel()
    try:
        await worker_task
    except asyncio.CancelledError:
        pass


if __name__ == "__main__":
    asyncio.run(main())
```

## Use Case Extensions

### Scenario 1: Real-time Data Synchronization

```python
async def sync_data_change(self, table_name: str, record_id: str, operation: str):
    message = f"{table_name}:{record_id}:{operation}"
    await self.publish("data_sync_channel", message)
```

### Scenario 2: Distributed Lock Notification

```python
async def notify_lock_release(self, lock_name: str):
    await self.publish("distributed_lock_channel", f"RELEASE:{lock_name}")
```

### Scenario 3: Cache Invalidation Broadcast

```python
async def invalidate_cache(self, cache_key: str):
    await self.publish("cache_invalidation_channel", cache_key)
```

## Important Notes

### Technical Limitations

1. **Message Size**: NOTIFY messages are limited to 8000 bytes
2. **No Persistence**: Messages are not persisted and are lost after restart
3. **No Acknowledgement**: Senders cannot know if a message was received
4. **No Order Guarantee**: Messages may arrive out of order

### Production Recommendations

1. **Monitoring**: Implement channel listening status monitoring
2. **Error Handling**: Add comprehensive error handling and logging
3. **Backup**: Important messages should have backup storage
4. **Performance Testing**: Test under high load

## Supplement

### asyncpg Version

`asyncpg` is a pure asynchronous Python driver for Postgres with better performance.

Installation:

```shell
uv add asyncpg
```

Code example:

```python
import asyncio
import signal
from typing import Set

import asyncpg

from pkg.config import cfg

MAX_CONCURRENT_TASKS = 5


class TaskWorker:
    def __init__(self, dsn: str, channel: str):
        self._dsn = dsn
        self._channel = channel
        self._pool: asyncpg.Pool | None = None
        self._listener_conn: asyncpg.Connection | None = None
        self._sem = asyncio.Semaphore(MAX_CONCURRENT_TASKS)
        self._active_tasks: Set[asyncio.Task] = set()

    async def start(self):
        if not self._pool:
            self._pool = await asyncpg.create_pool(
                dsn=self._dsn,
                min_size=cfg.postgres_pool_min_size(),
                max_size=cfg.postgres_pool_max_size(),
            )

        if not self._listener_conn:
            self._listener_conn = await asyncpg.connect(dsn=self._dsn)
            await self._listener_conn.add_listener(self._channel, self._on_notify)
            print(f"Listening on channel: {self._channel}")

        try:
            await asyncio.Future()
        except asyncio.CancelledError:
            pass
        finally:
            await self.stop()

    async def _on_notify(
        self, conn: asyncpg.Connection, pid: int, channel: str, payload: str
    ):
        if not payload:
            return

        task_id = payload.strip()
        print(f"Received notification: {task_id} on channel: {channel}")

        task = asyncio.create_task(self._handle_task(task_id))
        self._active_tasks.add(task)
        task.add_done_callback(self._active_tasks.discard)

    async def _handle_task(self, task_id: str):
        if not self._pool:
            raise RuntimeError("Database pool not initialized")
        async with self._sem:
            async with self._pool.acquire() as conn:
                try:
                    await self._execute_business_logic(task_id)
                    print(f"Task {task_id} completed successfully.")
                except Exception as e:
                    print(f"Task {task_id} failed: {e}")
                    await self._log_failure(task_id, str(e))

    async def _execute_business_logic(self, task_id: str):
        print(f"Processing task {task_id}...")
        await asyncio.sleep(5)
        print(f"Task {task_id} completed.")

    async def _log_failure(self, task_id: str, error: str):
        print(f"Task {task_id} failure logged: {error}")

    async def stop(self):
        print("Shutting down gracefully...")
        if self._active_tasks:
            await asyncio.gather(*self._active_tasks, return_exceptions=True)

        if self._listener_conn:
            await self._listener_conn.remove_listener(self._channel, self._on_notify)
            await self._listener_conn.close()

        if self._pool:
            await self._pool.close()

        print("Shutdown complete.")


async def main():
    worker = TaskWorker(cfg.get_postgres_dsn(), cfg.postgres_channel())
    loop = asyncio.get_running_loop()
    stop_evt = asyncio.Event()

    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, stop_evt.set)

    listen_task = asyncio.create_task(worker.start())

    await stop_evt.wait()
    print("Shutdown signal received, stopping worker...")

    listen_task.cancel()
    await listen_task


if __name__ == "__main__":
    asyncio.run(main())
```
