+++
date = '2026-02-08T23:56:57+08:00'
draft = false
title = 'Executing Asynchronous Scheduled Tasks with Database-Based Distributed Locking in FastAPI'
description = "This article provides a comprehensive guide on implementing an asynchronous task scheduler in FastAPI, using database-based distributed locks to prevent duplicate task execution in multi-process environments."
isCJKLanguage = false
categories = ["program"]
tags = ["python", "sqlalchemy", "fastapi", "sqlite"]
keywords = [
    "python",
    "sqlalchemy",
    "sqlite",
    "fastapi",
]
slug = "fastapi-schedule-async-job-with-db-lock"
+++

## Introduction

When implementing scheduled tasks in FastAPI applications, `Celery` is often the go-to choice. However, Celery is relatively heavyweight and requires dependencies like Redis or RabbitMQ as message brokers. For smaller-scale services that don't already utilize Redis or RabbitMQ, introducing these dependencies solely for scheduled task functionality adds unnecessary operational overhead.

Another popular Python scheduling framework is `APScheduler`, but it presents two significant challenges in practice:

1. **Duplicate Execution in Multi-Process Environments**: When running with Uvicorn's multi-process mode, each worker process independently executes scheduled tasks, leading to duplicate executions.
2. **Poor Asynchronous Function Compatibility**: Although APScheduler provides `AsyncIOScheduler`, its support for asynchronous functions is incomplete. The official documentation explicitly states: "If you're running an asynchronous web framework like aiohttp, you probably want to use a different scheduler in order to take some advantage of the asynchronous nature of the framework."

For APScheduler users facing these issues, potential solutions include:

1. Implementing a distributed locking mechanism (e.g., file locks, database locks, Redis locks, or ETCD locks) to ensure only one process executes each task at any given time.
2. Converting asynchronous task functions to synchronous ones.

This article takes a different approach: instead of relying on APScheduler, we implement a lightweight task scheduler from scratch. Our scheduler features three core capabilities:

1. **Cron Schedule Support**: Define task execution cycles using standard Cron expressions.
2. **One-Time Task Support**: Dynamically schedule tasks for execution at specific timestamps.
3. **Database-Based Distributed Locking**: Utilize SQLite to implement distributed locks, preventing duplicate task execution in multi-process environments. Thanks to SQLAlchemy's abstraction layer, migration to other databases is straightforward.

This implementation focuses on core task scheduling and addition functionality. Additional features like task updates and queries can be implemented similarly and are left as exercises for interested readers.

> **Note**: The example code is designed for demonstration purposes. In production environments, consider further optimizing code structure and error handling mechanisms.

## Dependency Installation

The following dependencies are required, with `croniter` used for parsing Cron expressions:

```bash
python -m pip install sqlalchemy>=2.0 aiosqlite croniter fastapi uvicorn
```

## Database Connection Configuration

```python
# pkg/database/rdb.py
from contextlib import asynccontextmanager
from typing import AsyncGenerator

from sqlalchemy import event
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import declarative_base

from pkg.config import settings

db_engine = create_async_engine(
    f"sqlite+aiosqlite:///data/{settings.sqlite_path}",
    echo=False,
    connect_args={
        "check_same_thread": False,
        "timeout": 15.0,
    },
)


# Enable WAL mode for SQLite on each connection
@event.listens_for(db_engine.sync_engine, "connect")  # Requires synchronous engine
def set_sqlite_pragma(dbapi_conn, connection_record):
    cursor = dbapi_conn.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA synchronous=NORMAL")  # Balance performance and safety
    cursor.execute(
        "PRAGMA wal_autocheckpoint=1000"
    )  # Auto-checkpoint every 1000 pages to prevent WAL file growth
    cursor.execute("PRAGMA busy_timeout=5000")  # Busy timeout of 5 seconds
    cursor.close()


# Asynchronous session factory
async_session = async_sessionmaker(
    db_engine,
    expire_on_commit=False,  # Recommended to disable in async contexts to prevent object invalidation after commit
    class_=AsyncSession,
    autoflush=False,
    autocommit=False,
)


@asynccontextmanager
async def get_db_session() -> AsyncGenerator[AsyncSession, None]:
    """For FastAPI dependency injection, automatically manages session lifecycle"""
    async with async_session() as session:
        try:
            yield session
        except Exception as e:
            await session.rollback()
            raise e


Base = declarative_base()
```

## Data Model Design

The system implements three core database tables:

- `scheduler_tasks`: Stores metadata for scheduled tasks
- `scheduler_locks`: Tracks distributed lock states
- `scheduler_logs`: Records task execution logs

```python
# pkg/database/models/scheduler.py
import enum

from sqlalchemy import Boolean, Column, DateTime, Enum, Integer, String, Text, func

from pkg.database.rdb import Base


class TaskType(enum.Enum):
    ONCE = "once"
    CRON = "cron"


class LastRunStatus(enum.Enum):
    SUCCESS = "success"
    FAILURE = "failure"
    RUNNING = "running"


class ScheduledTask(Base):
    __tablename__ = "scheduler_tasks"

    id = Column(Integer, primary_key=True, autoincrement=True)
    task_name = Column(String(255), unique=True, nullable=False)
    task_type = Column(Enum(TaskType), nullable=False)
    cron_expression = Column(
        String(100), nullable=True, comment="Cron expression, only used for cron type"
    )
    once_time = Column(
        DateTime(timezone=True),
        nullable=True,
        comment="Execution time for once-type tasks",
    )
    task_func = Column(Text, nullable=False, comment="The function path to execute")
    task_args = Column(
        Text,
        nullable=True,
        comment="Positional arguments for the task function, stored as JSON string",
    )
    task_kwargs = Column(
        Text,
        nullable=True,
        comment="Keyword arguments for the task function, stored as JSON string",
    )
    is_active = Column(Boolean, default=True, comment="Whether the task is active")

    last_run_time = Column(
        DateTime(timezone=True), nullable=True, comment="The last time the task was run"
    )
    last_run_status = Column(
        Enum(LastRunStatus), nullable=True, comment="The status of the last run"
    )
    last_run_error = Column(
        Text, nullable=True, comment="Error message if the last run failed"
    )
    next_run_time = Column(
        DateTime(timezone=True),
        nullable=True,
        comment="The next scheduled run time for the task",
    )

    created_at = Column(
        DateTime(timezone=True),
        server_default=func.now(),
        comment="The time when the task was created",
    )
    updated_at = Column(
        DateTime(timezone=True),
        onupdate=func.now(),
        comment="The time when the task was last updated",
    )


class TaskLock(Base):
    __tablename__ = "scheduler_locks"

    id = Column(Integer, primary_key=True, autoincrement=True)
    task_name = Column(String(255), unique=True, nullable=False)
    worker_id = Column(String(100), nullable=False)  # ID of the worker currently holding the lock
    locked_at = Column(DateTime(timezone=True), default=func.now())  # Lock acquisition time
    expired_at = Column(DateTime(timezone=True))  # Lock expiration time
    is_active = Column(Boolean, default=True)


class SchedulerLogs(Base):
    __tablename__ = "scheduler_logs"

    id = Column(Integer, primary_key=True, autoincrement=True)
    worker_id = Column(String(100), nullable=False)
    task_name = Column(String(255), nullable=False)
    task_type = Column(Enum(TaskType), nullable=False)
    status = Column(Enum(LastRunStatus), nullable=False)
    error_message = Column(Text, nullable=True)
    created_at = Column(DateTime(timezone=True), default=func.now())
```

Create table initialization functions that can be called within FastAPI's lifespan:

```python
# pkg/database/__init__.py
from .rdb import Base, db_engine


async def init_tables() -> None:
    async with db_engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


async def drop_tables() -> None:
    async with db_engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
```

Access to the `scheduler_logs` table is encapsulated as follows:

```python
# pkg/scheduler/services.py
from collections.abc import Sequence
from datetime import datetime, timedelta, timezone

from sqlalchemy import delete, select

from pkg.database.models.scheduler import LastRunStatus, SchedulerLogs, TaskType
from pkg.database.rdb import async_session


class SchedulerLogsService:
    @classmethod
    async def log_task_execution(
        cls,
        worker_id: str,
        task_name: str,
        task_type: TaskType,
        status: LastRunStatus,
        error: str = "",
    ) -> bool:
        try:
            async with async_session() as session:
                async with session.begin():
                    log_entry = SchedulerLogs(
                        worker_id=worker_id,
                        task_name=task_name,
                        task_type=task_type,
                        status=status,
                        error_message=error,
                        created_at=datetime.now(timezone.utc),
                    )
                    session.add(log_entry)
                    return True
        except Exception as e:
            return False

    @classmethod
    async def list_task_logs(
        cls,
        task_name: str = "",
        task_type: TaskType | None = None,
        limit: int = 10,
        offset: int = 0,
    ) -> Sequence[SchedulerLogs]:
        """List task execution logs

        Args:
            task_name (str, optional): Task name. Defaults to "".
            limit (int, optional): Number of records per page. Defaults to 10.
            offset (int, optional): Offset for pagination. Defaults to 0.

        Returns:
            Sequence[SchedulerLogs]: List of task execution logs
        """
        async with async_session() as session:
            stmt = select(SchedulerLogs)
            if task_name:
                stmt = stmt.where(SchedulerLogs.task_name == task_name)
            if task_type:
                stmt = stmt.where(SchedulerLogs.task_type == task_type)
            stmt = (
                stmt.order_by(SchedulerLogs.created_at.desc())
                .limit(limit)
                .offset(offset)
            )
            result = await session.execute(stmt)
            logs = result.scalars().all()
            return logs

    @classmethod
    async def cleanup_old_logs(cls, keep_days: int = 30) -> bool:
        """Clean up old logs

        Args:
            keep_days (int, optional): Number of days to retain logs. Defaults to 30.

        Returns:
            bool: Whether log cleanup was successful
        """
        async with async_session() as session:
            async with session.begin():
                stmt = delete(SchedulerLogs).where(
                    SchedulerLogs.created_at
                    < datetime.now(timezone.utc) - timedelta(days=keep_days)
                )
                result = await session.execute(stmt)
                return result.rowcount > 0  # type: ignore
```

## Scheduled Task Scheduler Implementation

### Distributed Locking Mechanism

First, we implement a database-based distributed lock. Ideally, we could define an abstract base class `DistributedLock` with abstract methods `acquire` and `release`, then provide concrete implementations for different lock types (e.g., `DistributedDBLock`, `DistributedFileLock`, `DistributedRedisLock`). This approach allows flexible selection of lock implementations based on actual business requirements.

```python
# pkg/scheduler/lock_manager.py
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Optional

from sqlalchemy import delete, select, update
from sqlalchemy.exc import IntegrityError

from pkg.database.models.scheduler import TaskLock
from pkg.database.rdb import async_session
from pkg.log import logger


class DistributedDBLock:
    def __init__(self, lock_time: int = 30):
        self.lock_time = lock_time
        self.worker_id = str(uuid.uuid4())

    async def acquire(self, task_name: str) -> bool:
        """Acquire lock"""
        now = datetime.now(tz=timezone.utc)
        expired_at = now + timedelta(seconds=self.lock_time)

        async with async_session() as session:
            try:
                logger.debug(
                    f"Worker {self.worker_id} attempting to acquire lock for task: {task_name}"
                )
                record = TaskLock(
                    task_name=task_name, worker_id=self.worker_id, expired_at=expired_at
                )
                session.add(record)
                await session.commit()
                return True
            except IntegrityError:
                # Unique constraint violation indicates lock already exists
                await session.rollback()

                logger.debug(
                    f"Worker {self.worker_id} failed to acquire lock for task: {task_name} - lock already exists"
                )

                # Retrieve existing lock record
                stmt = select(TaskLock).where(TaskLock.task_name == task_name)
                result = await session.execute(stmt)
                existing_lock: Optional[TaskLock] = result.scalar_one_or_none()

                # If lock exists, check if it has expired
                # If expired, attempt to update the lock record to acquire it
                if existing_lock is not None:
                    if (
                        existing_lock.expired_at is not None
                        and existing_lock.expired_at < now
                    ):  # type: ignore
                        await session.execute(
                            update(TaskLock)
                            .where(TaskLock.task_name == task_name)
                            .values(worker_id=self.worker_id, expired_at=expired_at)
                        )
                        await session.commit()
                        logger.debug(
                            f"Worker {self.worker_id} acquired lock for task: {task_name}"
                        )
                        return True
                return False
            except Exception as e:
                await session.rollback()
                return False

    async def release(self, task_name: str) -> None:
        """Release lock"""
        async with async_session() as session:
            try:
                await session.execute(
                    delete(TaskLock).where(TaskLock.task_name == task_name)
                )
                await session.commit()
                logger.debug(
                    f"Worker {self.worker_id} released lock for task: {task_name}"
                )
            except Exception as e:
                await session.rollback()

    async def renew(self, task_name: str) -> bool:
        """Renew lock expiration"""
        expired_at = datetime.now(tz=timezone.utc) + timedelta(seconds=self.lock_time)

        async with async_session() as session:
            try:
                stmt = (
                    update(TaskLock)
                    .where(TaskLock.task_name == task_name)
                    .values(worker_id=self.worker_id, expired_at=expired_at)
                )
                result = await session.execute(stmt)
                await session.commit()
                # return len(result.fetchall()) > 0
                return result.rowcount > 0  # type: ignore[union-attr]
            except Exception as e:
                await session.rollback()
                return False

    async def cleanup_expired_locks(self) -> bool:
        """Clean up expired locks"""
        now = datetime.now(tz=timezone.utc)
        async with async_session() as session:
            try:
                stmt = delete(TaskLock).where(TaskLock.expired_at < now)
                result = await session.execute(stmt)
                await session.commit()
                return result.rowcount > 0  # type: ignore[union-attr]
            except Exception as e:
                await session.rollback()
                return False

    @asynccontextmanager
    async def lock(self, task_name: str):
        """Context manager for lock acquisition and release"""
        acquired = await self.acquire(task_name)
        try:
            if not acquired:
                raise Exception(f"Failed to acquire lock for task: {task_name}")
            yield
        finally:
            if acquired:
                await self.release(task_name)
```

### Asynchronous Task Scheduler

```python
# pkg/scheduler/scheduler.py
# type: ignore
import asyncio
import json
from datetime import datetime, timedelta, timezone
from functools import partial
from typing import Callable, Dict, Optional

from croniter import croniter
from sqlalchemy import select

from pkg.database.models.scheduler import LastRunStatus, ScheduledTask, TaskType
from pkg.database.rdb import async_session
from pkg.log import logger

from .lock_manager import DistributedDBLock
from .services import SchedulerLogsService


class AsyncScheduler:
    def __init__(self):
        self.lock_manager = DistributedDBLock()
        self.task_registry: Dict[str, Callable] = {}
        self.running: bool = False
        self.background_task: Optional[asyncio.Task] = None

    def register_task(self, task_name: str, task_func: Callable) -> None:
        """Register a task function

        Args:
            task_name (str): Task name
            task_func (Callable): Task function

        Raises:
            ValueError: If task name or function is empty
        """
        if not task_name or not task_func:
            raise ValueError("Task name and function must be provided")
        self.task_registry[task_name] = task_func

    async def add_cron_task(
        self,
        task_name: str,
        cron: str,
        func: Callable,
        args: tuple = (),
        kwargs: dict = {},
    ) -> None:
        """Add or update a cron-scheduled task

        Args:
            task_name (str): Task name
            cron (str): Cron expression
            func (Callable): Task function

        Raises:
            ValueError: If cron expression is invalid
        """
        if not croniter.is_valid(cron):
            raise ValueError("Invalid cron expression")
        async with async_session() as session:
            result = await session.execute(
                select(ScheduledTask).where(ScheduledTask.task_name == task_name)
            )
            existed_task = result.scalar_one_or_none()
            if existed_task:
                existed_task.task_type = TaskType.CRON
                existed_task.cron_expression = cron
                existed_task.task_func = f"{func.__module__}.{func.__name__}"
                existed_task.task_args = json.dumps(args)
                existed_task.task_kwargs = json.dumps(kwargs)
                existed_task.is_active = True
                existed_task.next_run_time = self._calculate_next_run(cron)
                logger.debug(
                    f"Updated existing cron task: {task_name} with schedule {cron}"
                )
            else:
                task = ScheduledTask(
                    task_name=task_name,
                    task_type=TaskType.CRON,
                    cron_expression=cron,
                    task_func=f"{func.__module__}.{func.__name__}",
                    task_args=json.dumps(args),
                    task_kwargs=json.dumps(kwargs),
                    is_active=True,
                    next_run_time=self._calculate_next_run(cron),
                )
                session.add(task)
                logger.debug(f"Added new cron task: {task_name} with schedule {cron}")
            try:
                await session.commit()
            except Exception as e:
                await session.rollback()
                logger.error(f"Failed to add cron task: {e}")
                # raise e
        self.register_task(task_name, func)
        logger.info(f"Added/updated cron task: {task_name} with schedule {cron}")

    async def add_once_task(
        self,
        task_name: str,
        execute_time: datetime,
        func: Callable,
        args: tuple = (),
        kwargs: dict = {},
    ) -> None:
        """Add a one-time task

        Args:
            task_name (str): Task name
            execute_time (datetime): Execution time (must be in UTC timezone)
            func (Callable): Task function

        Raises:
            ValueError: If execution time is invalid
        """
        async with async_session() as session:
            task = ScheduledTask(
                task_name=task_name,
                task_type=TaskType.ONCE,
                once_time=execute_time,
                task_func=f"{func.__module__}.{func.__name__}",
                task_args=json.dumps(args),
                task_kwargs=json.dumps(kwargs),
                is_active=True,
                next_run_time=execute_time,
            )
            try:
                session.add(task)
                await session.commit()
                logger.debug(
                    f"Added new once task: {task_name} scheduled at {execute_time.isoformat()}"
                )
            except Exception as e:
                await session.rollback()
                logger.error(f"Failed to add once task: {e}")
                # raise e
        self.register_task(task_name, func)

    def _calculate_next_run(self, cron: str) -> datetime:
        """Calculate next execution time

        Args:
            cron (str): Cron expression

        Returns:
            datetime: Next execution time (UTC timezone)
        """
        # if not croniter.is_valid(cron):
        #     raise ValueError("Invalid cron expression")
        now = datetime.now(tz=timezone.utc)
        iter = croniter(cron, now)
        next_run = iter.get_next(datetime)
        # Ensure returned time is explicitly set to UTC timezone
        if next_run.tzinfo is None:
            next_run = next_run.replace(tzinfo=timezone.utc)
        return next_run

    async def _execute_task(self, task_id: int, task_name: str) -> None:
        """Execute a scheduled task

        Args:
            task_id (int): Task ID
            task_name (str): Task name
        """
        task = None  # Ensure task is accessible in finally block
        try:
            lock_acquired = await self.lock_manager.acquire(task_name)
            if not lock_acquired:
                logger.debug(f"Could not acquire lock for task: {task_name}")
                return

            try:
                async with async_session() as session:
                    task_record = await session.execute(
                        select(ScheduledTask).where(ScheduledTask.id == task_id)
                    )
                    task = task_record.scalar_one_or_none()
                    if not task or not task.is_active:
                        logger.warning(f"Task not found or inactive: {task_name}")
                        return

                    task.last_run_time = datetime.now(tz=timezone.utc)
                    task.last_run_status = LastRunStatus.RUNNING
                    await session.commit()
                    await session.flush()  # Ensure status updates are written to database promptly
                    await session.refresh(task)  # Refresh object state to get latest data

                func = self.task_registry.get(task_name)
                if not func:
                    logger.error(f"Task function not found for task: {task.task_name}")
                    return

                args = json.loads(task.task_args) if task.task_args else ()
                kwargs = json.loads(task.task_kwargs) if task.task_kwargs else {}

                logger.info(
                    f"Worker ID: {self.lock_manager.worker_id}, Executing task: {task.task_name}"
                )

                # Handle both synchronous and asynchronous task functions
                if asyncio.iscoroutinefunction(func):
                    await func(*args, **kwargs)
                else:
                    logger.warning(
                        f"Task function {func.__name__} is not asynchronous, running in executor"
                    )
                    loop = asyncio.get_event_loop()
                    await loop.run_in_executor(None, partial(func, *args, **kwargs))

                async with async_session() as session:
                    task_record = await session.execute(
                        select(ScheduledTask).where(ScheduledTask.id == task_id)
                    )
                    task = task_record.scalar_one_or_none()
                    if task:
                        task.last_run_status = LastRunStatus.SUCCESS
                        task.last_run_error = None
                        await SchedulerLogsService.log_task_execution(
                            self.lock_manager.worker_id,
                            task.task_name,
                            task.task_type,
                            task.last_run_status,
                        )

                        if task.task_type == TaskType.CRON:
                            task.next_run_time = self._calculate_next_run(
                                task.cron_expression
                            )
                        else:
                            task.is_active = False  # Disable one-time tasks after execution

                        await session.commit()
            finally:
                if task:
                    await self.lock_manager.release(str(task.task_name))
        except Exception as e:
            logger.error(f"Error executing task {task.task_name}: {e}")
            try:
                async with async_session() as session:
                    task_record = await session.execute(
                        select(ScheduledTask).where(ScheduledTask.id == task_id)
                    )
                    task = task_record.scalar_one_or_none()
                    if task:
                        task.last_run_status = LastRunStatus.FAILURE
                        task.last_run_error = str(e)
                        await session.commit()
                        await SchedulerLogsService.log_task_execution(
                            self.lock_manager.worker_id,
                            task.task_name,
                            task.task_type,
                            task.last_run_status,
                            task.last_run_error,
                        )
            except Exception as e:
                logger.error(f"Error updating task status: {e}")

    async def _scheduler_loop(self):
        while self.running:
            try:
                await self.lock_manager.cleanup_expired_locks()

                async with async_session() as session:
                    now = datetime.now(tz=timezone.utc)
                    stmt = select(ScheduledTask).where(
                        ScheduledTask.is_active,
                        ScheduledTask.next_run_time <= now,
                        ScheduledTask.next_run_time > now - timedelta(seconds=10),
                    )
                    result = await session.execute(stmt)
                    tasks_to_run = result.scalars().all()

                if tasks_to_run:
                    await asyncio.gather(
                        *[
                            self._execute_task(task.id, task.task_name)
                            for task in tasks_to_run
                        ],
                        return_exceptions=True,
                    )

                await asyncio.sleep(1)
            except Exception as e:
                logger.error(f"Error in scheduler loop: {e}")
                await asyncio.sleep(5)  # Brief pause before continuing on error

    async def start(self):
        if self.running:
            return

        self.running = True
        self.background_task = asyncio.create_task(self._scheduler_loop())
        logger.info(f"Scheduler started, worker_id: {self.lock_manager.worker_id}")

    async def stop(self):
        if not self.running:
            return

        self.running = False
        if self.background_task:
            self.background_task.cancel()
            try:
                await self.background_task
            except asyncio.CancelledError:
                pass
        logger.info("Scheduler stopped")
```

Instantiate the asynchronous scheduler in `__init__.py` as a singleton for use by other modules:

```python
# pkg/scheduler/__init__.py
from .scheduler import AsyncScheduler

scheduler = AsyncScheduler()

__all__ = [
    "scheduler",
]
```

## Defining Asynchronous Task Functions

Here are some example task functions for testing:

```python
# jobs/__init__.py
import asyncio
from random import randint

from pkg.log import logger


async def send_email_notification(user_id: int, message: str) -> dict:
    await asyncio.sleep(10)  # Simulate async email sending
    logger.info(f"Sent email notification to user {user_id}: {message}")
    return {"status": "sent", "user_id": user_id, "message": message}


async def send_email_notification_fail() -> None:
    user_id = randint(1, 100)
    message = "This is a test email notification that may fail."
    await asyncio.sleep(10)  # Simulate async email sending
    logger.info(f"Sent email notification to user {user_id}: {message}")
    bullet_chamber = randint(1, 4)
    trigger_position = randint(1, 4)
    if bullet_chamber == trigger_position:
        logger.error(f"Email sending failed for user {user_id}: {message}")
        raise Exception("Failed to send email due to a random error")


async def cleanup_temp_files() -> None:
    await asyncio.sleep(15)
    logger.info("Cleaned up temporary files")


async def generate_daily_report() -> None:
    await asyncio.sleep(3)
    logger.info("Generated daily report")
```

## FastAPI Application Integration

In our demonstration application, we register scheduled tasks directly in the lifespan and provide an API endpoint for dynamically adding one-time tasks.

```python
# main.py
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone

import uvicorn
from fastapi import FastAPI

from jobs import (
    cleanup_temp_files,
    generate_daily_report,
    send_email_notification,
    send_email_notification_fail,
)
from pkg.database import drop_tables, init_tables
from pkg.scheduler import scheduler


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_tables()
    await scheduler.start()

    # Register scheduled tasks
    await scheduler.add_cron_task(
        task_name="cleanup_temp_files", func=cleanup_temp_files, cron="* * * * *"
    )
    await scheduler.add_cron_task(
        task_name="generate_daily_report",
        func=generate_daily_report,
        cron="35 16 * * *",
    )
    await scheduler.add_cron_task(
        task_name="send_email_notification_fail",
        func=send_email_notification_fail,
        cron="* * * * *",
    )

    yield
    await scheduler.stop()
    # await drop_tables()


app = FastAPI(lifespan=lifespan)


@app.get("/")
async def get_root():
    return {"message": "Hello, World!"}


@app.put("/send_email_notification")
async def put_send_email_notification(user_id: int, message: str):
    now = datetime.now(tz=timezone.utc)
    await scheduler.add_once_task(
        task_name=f"send_email_notification_{user_id}",
        func=send_email_notification,
        args=(user_id, message),
        execute_time=now + timedelta(seconds=10),
    )
    return {
        "message": f"Task scheduled to send email notification to user {user_id} in 10 seconds"
    }


if __name__ == "__main__":
    # Start with 4 worker processes for testing
    uvicorn.run("main:app", host="127.0.0.1", port=10001, workers=4)
```

## Running Tests

After starting the service, observe the console logs to verify that tasks are not being executed multiple times. You can also test dynamic one-time task scheduling with the following command:

```bash
curl -X PUT 'http://127.0.0.1:10001/send_email_notification?user_id=1234&message=hello'
```

## Conclusion

Through this implementation, we have successfully built a lightweight asynchronous task scheduler that effectively addresses the duplicate execution problem in multi-process environments. Key takeaways include:

1. **Distributed Locking Mechanism**: Implemented using database unique constraints to ensure only one worker process executes each task at any given time.
2. **Flexible Task Types**: Supports both Cron-scheduled tasks and one-time temporary tasks.
3. **Asynchronous Compatibility**: Properly handles both asynchronous and synchronous task functions.
4. **Extensibility**: SQLAlchemy-based design makes database migration straightforward.

For more complex scenarios, consider the following enhancements:

- **Task Persistence**: Persist task registration information to the database to support dynamic task management.
- **Task Monitoring**: Provide a web UI or API endpoints for monitoring task status and execution history.
- **High Availability**: In microservice architectures, deploy the scheduler as a dedicated service with remote task execution capabilities.
- **Task Queues**: For long-running tasks, integrate with task queue systems for asynchronous processing.

Additionally, regarding task function definition, an object-oriented approach could be considered by defining an abstract base class `Job` and using the `__init_subclass__()` mechanism for automatic task registration, providing better type safety and code organization.