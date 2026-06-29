+++
date = '2026-06-07T23:58:30+08:00'
draft = false
title = 'Deepagents - Using Postgres as Checkpointer'
description = 'Using Postgres as checkpointer for Deepagents'
summary = 'Persistent checkpoint with Postgres for DeepAgents'
isCJKLanguage = false
categories = [
    "program"
]
tags = [
    "deepagents",
    "python",
    "ai",
    "AI-Translated"
]
slug = 'deepagents-postgres-as-checkpointer'
+++

## Introduction

When building a chatbot with DeepAgents, there's a fundamental requirement: the Agent needs to remember what was discussed in the previous conversation. You can't ask users to reintroduce themselves every round.

LangGraph / DeepAgents has a built-in mechanism called checkpoint to handle this. Using `MemorySaver` for demos during development works fine, but in production — where service restarts wipe all state and multi-instance deployments can't share memory — it's time to switch to Postgres.

This article documents my process of using `langgraph-checkpoint-postgres` for persistent checkpointing in a FastAPI-based project, along with connection pool configuration and pitfalls with PG server-side idle timeouts.

Core dependencies:

```
langgraph-checkpoint-postgres>=3.1.0
psycopg[binary,pool]>=3.3.4
deepagents>=0.4.12
fastapi>=0.135.2
```

## What is a Checkpoint

In LangGraph, an Agent's execution is essentially a directed graph: LLM calls, tool executions, conditional branches — each step can change the state. A checkpoint is an **automatic state snapshot** saved after each node executes, containing the current message history, intermediate variables, and where the graph is in its execution.

Think of it like saving your game: save mid-game, and you can resume from that save later instead of starting over.

At the code level, this is represented by the `thread_id` in `RunnableConfig`:

```python
config = RunnableConfig(
    callbacks=[cb],
    configurable={"thread_id": session_id}
)

async for chunk in ai_agent.astream(msg.content, config=config):
    await final_answer.stream_token(chunk)
```

Messages with the same `thread_id` are written to the same checkpoint chain. The next time the agent is called with that `thread_id`, LangGraph automatically restores state from the most recent checkpoint, and the user has no idea anything was "reloaded."

## Why Postgres Instead of MemorySaver

`MemorySaver` stores checkpoints in process memory, which is very convenient for development and debugging — one line of code and you're done. But the problems are obvious:

1. **Lost on restart** — process exits, memory is freed, all conversation history is cleared.
2. **Can't share across instances** — if you run multiple workers (uvicorn `--workers 4`), each process has its own MemorySaver. A user's request might hit worker A one time and worker B the next, losing context.

Postgres as an external persistent storage naturally solves both problems. `langgraph-checkpoint-postgres` provides `AsyncPostgresSaver`, which internally manages three tables: `checkpoints` (state snapshots), `checkpoint_writes` (write operation records), and `checkpoint_blobs` (serialized data).

Table creation is done by calling `setup()` once at startup:

```python
conn_string = (
    f"postgresql://{cfg.PG_USER}:{cfg.PG_PASSWORD}"
    f"@{cfg.PG_HOST}:{cfg.PG_PORT}/{cfg.PG_DB}"
)

async with AsyncPostgresSaver.from_conn_string(conn_string) as temp_saver:
    await temp_saver.setup()
```

## Connection Pool: Using psycopg_pool's AsyncConnectionPool

### Why a Connection Pool

Every `ainvoke` or `astream` call interacts with Postgres multiple times (reading previous checkpoints, writing new ones). If each interaction opened a new database connection, three messages could max out PG's `max_connections`.

A more sensible approach is to reuse connections — initialize a connection pool, and `AsyncPostgresSaver` takes connections from the pool and returns them after use.

### Configuration Code

`psycopg_pool`'s `AsyncConnectionPool` is widely used and configuration is straightforward:

```python
from urllib.parse import quote_plus
from psycopg_pool import AsyncConnectionPool

_PG_POOL: AsyncConnectionPool = None

def _init_pg_pool():
    global _PG_POOL
    if not _PG_POOL:
        _PG_POOL = AsyncConnectionPool(
            f"postgresql://{quote_plus(cfg.PG_USER)}:"
            f"{quote_plus(cfg.PG_PASSWORD)}@"
            f"{cfg.PG_HOST}:{cfg.PG_PORT}/{cfg.PG_DB}",
            min_size=cfg.PG_POOL_MIN_SIZE,
            max_size=cfg.PG_POOL_MAX_SIZE,
            open=False,
        )

async def get_pg_pool() -> AsyncConnectionPool:
    global _PG_POOL
    if not _PG_POOL:
        _init_pg_pool()
    await _PG_POOL.open()
    return _PG_POOL
```

Key configuration points:

- **`min_size` / `max_size`**: The pool always keeps `min_size` idle connections ready; it scales up to `max_size` under load. In practice, `min=4, max=10` is sufficient, depending on concurrency.
- **`open=False`**: The pool object is created without immediately connecting to the database. Since `_init_pg_pool()` may be called at module import time (lazy singleton), using `open=True` would attempt to connect during import — if the database isn't ready yet, the whole application fails to start.
- **URL encoding**: `quote_plus` prevents injection if usernames or passwords contain special characters.

### AsyncPostgresSaver Reuses the Connection Pool

Once you have the pool, pass it directly to `AsyncPostgresSaver`:

```python
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

_PG_CHECKPOINTER: AsyncPostgresSaver = None

async def init_checkpointer(
    pg_pool: AsyncConnectionPool, is_setup: bool = False
) -> None:
    global _PG_CHECKPOINTER
    if not _PG_CHECKPOINTER:
        _PG_CHECKPOINTER = AsyncPostgresSaver(conn=pg_pool)

    if is_setup:
        conn_string = (...)
        async with AsyncPostgresSaver.from_conn_string(conn_string) as temp_saver:
            await temp_saver.setup()
```

Note that `setup()` uses a separate `from_conn_string` temporary connection rather than one from the pool.

## The Pitfall of PG Server-Side Idle Timeout

### The Problem

Postgres has two timeout parameters that can conflict with connection pools:

- **`idle_session_timeout`** (PG 14+): Kills connections idle for more than N seconds. **It doesn't distinguish whether a connection is in a transaction** — if no query is running, it's considered idle. This is the most destructive — those `min_size` idle connections in the pool get killed by PG after a while.
- **`idle_in_transaction_session_timeout`**: Kills connections that are in a transaction but doing nothing for more than N seconds. More lenient than the above — only targets connections "loafing in a transaction."

These parameters often have default values on cloud PG instances (e.g., Alibaba Cloud RDS defaults to `idle_session_timeout = 600s`, `idle_in_transaction_session_timeout = 60s`), and you might not even know they're enabled.

In our scenario, `AsyncPostgresSaver` opens a transaction when writing checkpoints. If the agent does heavy work between two checkpoint writes (like waiting for an LLM response for tens of seconds), the connection may be targeted by `idle_in_transaction_session_timeout`. Meanwhile, idle connections maintained by `min_size` get picked off by `idle_session_timeout`.

What happens after being killed? The connection pool doesn't know — the connection object still looks valid in the pool, but the underlying TCP connection is already broken. The next `getconn()` call will throw `OperationalError`, ruining the user experience.

### Solutions

**Solution 1: Increase server-side parameters (if you have permission)**

```sql
ALTER SYSTEM SET idle_session_timeout = 0;
ALTER SYSTEM SET idle_in_transaction_session_timeout = 0;
SELECT pg_reload_conf();
```

Or set them higher based on business patterns, e.g., `idle_session_timeout = '10min'`. Cloud databases usually don't allow these changes, so Solution 2 is more practical.

**Solution 2: Proactive pool recycling, ahead of PG kills**

`AsyncConnectionPool` supports parameters to control connection lifecycle:

```python
_PG_POOL = AsyncConnectionPool(
    conninfo,
    min_size=4,
    max_size=10,
    max_idle=300,        # Recycle connections idle for more than 300s
    max_lifetime=1800,   # Force recycle connections older than 30min
    open=False,
)
```

If PG's `idle_session_timeout` is 600s, set `max_idle` to 500s; if `idle_in_transaction_session_timeout` is 60s, set `max_idle` to 50s. In short, keep the pool's threshold slightly below PG's so the pool recycles connections before PG kills them. Additionally, `max_lifetime` provides a safety net — regardless of connection state, recycle at that time.

> If these parameters aren't passed when constructing `AsyncPostgresSaver`, the underlying `AsyncConnectionPool` defaults to `max_idle=600` (10 min) and `max_lifetime=3600` (1 hour). If your PG instance's idle timeout is smaller than these values, you must explicitly override them.

**Solution 3: TCP keepalive**

Add keepalive parameters to the connection string:

```python
conninfo = (
    f"postgresql://{user}:{pwd}@{host}:{port}/{db}"
    f"?keepalives=1"
    f"&keepalives_idle=30"
    f"&keepalives_interval=10"
    f"&keepalives_count=3"
)
```

TCP-level heartbeat keeps connections alive, preventing intermediate network devices (load balancers, firewalls) from dropping connections due to prolonged inactivity. However, this addresses network-layer timeouts, not PG's `idle_in_transaction_session_timeout`.

**Solution 4: Health check via `check` callback**

```python
async def check_connection(conn):
    try:
        await conn.execute("SELECT 1")
    except Exception:
        raise

_PG_POOL = AsyncConnectionPool(
    conninfo,
    check=check_connection,
    ...
)
```

Combining Solution 1/2 + 4 covers most scenarios.

## Application Lifecycle Management

The entire flow sits in FastAPI's lifespan:

```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    try:
        pg_pool = await get_pg_pool()
        await init_checkpointer(pg_pool, is_setup=True)
        yield
    finally:
        if pg_pool:
            await pg_pool.close()
```

Simple logic: create pool at startup → initialize checkpointer and create tables → run → close connections at shutdown. `is_setup=True` is passed only once at startup; subsequent `get_checkpointer()` calls use lazy loading and won't create tables again.

`get_checkpointer()` is a lazy singleton:

```python
async def get_checkpointer() -> AsyncPostgresSaver:
    global _PG_CHECKPOINTER
    if not _PG_CHECKPOINTER:
        pg_pool = await get_pg_pool()
        await init_checkpointer(pg_pool)
    return _PG_CHECKPOINTER
```

The Agent layer can simply call `await get_checkpointer()` to get the instance without worrying about initialization details.

## Agent-Side Integration in One Line

In deepagents' `create_deep_agent()`, checkpointer is just a parameter:

```python
class AIAgent:
    async def _init_deep_agent(self):
        if self._agent:
            return

        checkpointer = await get_checkpointer()

        self._agent = create_deep_agent(
            model=self._llm,
            tools=self._tools,
            checkpointer=checkpointer,
            middleware=[...],
        )
```

After that, every `astream` call with a `thread_id` in `RunnableConfig` automatically loads context from Postgres and saves checkpoints after execution. Streaming scenarios work the same way — no extra handling needed.

## Improvements

- **Checkpoint table bloat**: Over time, the `checkpoints` table grows. LangGraph currently has no built-in cleanup strategy. You need to write a scheduled task to clean old records by `thread_id` and time conditions.
- **Pool size tuning**: `min_size=4` might not suit every scenario. Monitor PG's `pg_stat_activity` after deployment and adjust based on active connections.
- **Multi-instance deployment**: With multiple workers sharing the same Postgres, `thread_id` works across instances naturally. As long as the same user session always uses the same `thread_id`, requests can hit any worker and still restore context correctly. For WebSocket scenarios, consider sticky sessions or persisting `thread_id` on the client side.
- **`open=False` + manual `open()` pattern**: This ensures no connection is made at import time, but if you forget to call `await _PG_POOL.open()` in the lifespan, all subsequent database operations will fail with `PoolIsClosed`. The current code handles this by automatically opening in `get_pg_pool()`.
