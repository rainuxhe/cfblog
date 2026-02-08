+++
date = '2026-02-08T23:56:57+08:00'
draft = false
title = 'FastAPI 执行异步定时任务：基于数据库的分布式锁实现'
description = "本文详细介绍如何在 FastAPI 中实现异步定时任务调度器，通过数据库分布式锁解决多进程环境下的任务重复执行问题。"
isCJKLanguage = true
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

## 前言

在 FastAPI 应用中执行定时任务，通常可以选择 `celery`，但 Celery 相对重量级，且需要依赖 Redis 或 RabbitMQ 等消息队列。当服务规模较小，且原本未使用 Redis 或 RabbitMQ 时，仅为定时任务功能引入这些依赖会增加额外的运维成本。

Python 生态中还有另一个主流的定时任务框架——`APScheduler`，但在实际使用中发现两个主要问题：

1. **多进程重复执行问题**：当使用 Uvicorn 多进程模式启动时，每个工作进程都会独立运行定时任务，导致任务被重复执行。
2. **异步函数兼容性问题**：虽然 APScheduler 提供了 `AsyncIOScheduler`，但其对异步函数的支持并不完善。官方文档也明确指出："If you're running an asynchronous web framework like aiohttp, you probably want to use a different scheduler in order to take some advantage of the asynchronous nature of the framework."

针对 APScheduler 的这些问题，如果仍选择使用它，可以考虑以下解决方案：

1. 实现分布式锁机制（如文件锁、数据库锁、Redis 锁、ETCD 锁等），确保每个任务在同一时间仅由一个进程执行。
2. 将异步任务函数改为同步函数。

本文采用了一种不同的方案：不依赖 APScheduler，而是自行实现一个轻量级的任务调度模块。该调度器具备以下核心特性：

1. **支持 Cron 定时任务**：通过标准的 Cron 表达式定义任务执行周期。
2. **支持一次性临时任务**：可动态添加指定时间点执行的一次性任务。
3. **基于数据库的分布式锁**：使用 SQLite 实现分布式锁机制，确保在多进程环境下任务不会重复执行。由于底层使用 SQLAlchemy，可轻松迁移至其他数据库。

本文主要聚焦于任务添加和调度的核心实现。实际上，还可以扩展实现任务更新、查询等管理功能，但其实现方式与任务添加类似，因此不再赘述。

> **注意**：示例代码为演示目的而编写，实际生产环境中建议进一步优化代码结构和错误处理机制。

## 依赖安装

本文使用以下依赖包，其中 `croniter` 用于解析 Cron 表达式：

```bash
python -m pip install sqlalchemy>=2.0 aiosqlite croniter fastapi uvicorn
```

## 数据库连接配置

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


# 每次连接时为 SQLite 启用 WAL 模式
@event.listens_for(db_engine.sync_engine, "connect")  # 需要使用同步引擎
def set_sqlite_pragma(dbapi_conn, connection_record):
    cursor = dbapi_conn.cursor()
    cursor.execute("PRAGMA journal_mode=WAL")
    cursor.execute("PRAGMA synchronous=NORMAL")  # 平衡性能与安全性
    cursor.execute(
        "PRAGMA wal_autocheckpoint=1000"
    )  # 每 1000 页自动 checkpoint，避免 WAL 文件过大
    cursor.execute("PRAGMA busy_timeout=5000")  # 忙等待 5 秒
    cursor.close()


# 异步会话工厂
async_session = async_sessionmaker(
    db_engine,
    expire_on_commit=False,  # 异步场景建议关闭，避免提交后对象失效
    class_=AsyncSession,
    autoflush=False,
    autocommit=False,
)


@asynccontextmanager
async def get_db_session() -> AsyncGenerator[AsyncSession, None]:
    """用于 FastAPI 依赖注入，自动管理会话生命周期"""
    async with async_session() as session:
        try:
            yield session
        except Exception as e:
            await session.rollback()
            raise e


Base = declarative_base()
```

## 数据模型设计

系统设计了三个核心数据表：

- `scheduler_tasks`：存储定时任务的元数据信息
- `scheduler_locks`：记录分布式锁状态
- `scheduler_logs`：记录定时任务的执行日志

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
    worker_id = Column(String(100), nullable=False)  # 当前持有锁的工作进程 ID
    locked_at = Column(DateTime(timezone=True), default=func.now())  # 锁定时间
    expired_at = Column(DateTime(timezone=True))  # 锁过期时间
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

创建用于初始化数据库表的函数，可在 FastAPI 的 lifespan 中调用：

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

对 `scheduler_logs` 表的访问进行了封装：

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
        """列出任务日志

        Args:
            task_name (str, optional): 任务名称. Defaults to "".
            limit (int, optional): 每页数量. Defaults to 10.
            offset (int, optional): 偏移量. Defaults to 0.

        Returns:
            Sequence[SchedulerLogs]: 任务日志列表
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
        """清理旧日志

        Args:
            keep_days (int, optional): 保留天数. Defaults to 30.

        Returns:
            bool: 是否成功清理日志
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

## 定时任务调度器实现

### 分布式锁机制

首先实现基于数据库的分布式锁。理想情况下，可以先定义一个抽象基类 `DistributedLock`，包含 `acquire` 和 `release` 抽象方法，然后根据不同的锁实现（如 `DistributedDBLock`、`DistributedFileLock`、`DistributedRedisLock`）提供具体实现。这样可以根据实际业务场景灵活选择锁的实现方式。

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
        """获取锁"""
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
                # 遇到唯一性约束冲突，说明锁已存在
                await session.rollback()

                logger.debug(
                    f"Worker {self.worker_id} failed to acquire lock for task: {task_name} - lock already exists"
                )

                # 获取已存在的锁记录
                stmt = select(TaskLock).where(TaskLock.task_name == task_name)
                result = await session.execute(stmt)
                existing_lock: Optional[TaskLock] = result.scalar_one_or_none()

                # 锁已存在，判断是否已过期
                # 如果锁已过期，尝试更新锁记录以获取锁
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
        """释放锁"""
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
        """续期锁"""
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
        """清理过期的锁"""
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
        """上下文管理器"""
        acquired = await self.acquire(task_name)
        try:
            if not acquired:
                raise Exception(f"Failed to acquire lock for task: {task_name}")
            yield
        finally:
            if acquired:
                await self.release(task_name)
```

### 异步任务调度器

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
        """注册任务

        Args:
            task_name (str): 任务名称
            task_func (Callable): 任务函数

        Raises:
            ValueError: 如果任务名称或函数为空
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
        """添加或更新定时任务

        Args:
            task_name (str): 任务名称
            cron (str): 定时表达式
            func (Callable): 任务函数

        Raises:
            ValueError: 如果 Cron 表达式无效
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
        """添加一次性任务

        Args:
            task_name (str): 任务名称
            execute_time (datetime): 执行时间（必须为 UTC 时区）
            func (Callable): 任务函数

        Raises:
            ValueError: 如果执行时间无效
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
        """计算下一次运行时间

        Args:
            cron (str): 定时表达式

        Returns:
            datetime: 下一次运行时间（UTC 时区）
        """
        # if not croniter.is_valid(cron):
        #     raise ValueError("Invalid cron expression")
        now = datetime.now(tz=timezone.utc)
        iter = croniter(cron, now)
        next_run = iter.get_next(datetime)
        # 确保返回的时间明确设置为 UTC 时区
        if next_run.tzinfo is None:
            next_run = next_run.replace(tzinfo=timezone.utc)
        return next_run

    async def _execute_task(self, task_id: int, task_name: str) -> None:
        """执行任务

        Args:
            task_id (int): 任务 ID
            task_name (str): 任务名称
        """
        task = None  # 确保 task 在 finally 块中可访问
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
                    await session.flush()  # 确保状态更新及时写入数据库
                    await session.refresh(task)  # 刷新对象状态，获取最新数据

                func = self.task_registry.get(task_name)
                if not func:
                    logger.error(f"Task function not found for task: {task.task_name}")
                    return

                args = json.loads(task.task_args) if task.task_args else ()
                kwargs = json.loads(task.task_kwargs) if task.task_kwargs else {}

                logger.info(
                    f"Worker ID: {self.lock_manager.worker_id}, Executing task: {task.task_name}"
                )

                # 任务函数可能是同步的也可能是异步的，这里做兼容处理
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
                            task.is_active = False  # 一次性任务执行后禁用

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
                await asyncio.sleep(5)  # 出现错误时稍微等待一下再继续循环

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

在 `__init__.py` 中实例化异步调度器，其他模块可直接使用该单例：

```python
# pkg/scheduler/__init__.py
from .scheduler import AsyncScheduler

scheduler = AsyncScheduler()

__all__ = [
    "scheduler",
]
```

## 定义异步任务函数

以下是一些用于测试的示例任务函数：

```python
# jobs/__init__.py
import asyncio
from random import randint

from pkg.log import logger


async def send_email_notification(user_id: int, message: str) -> dict:
    await asyncio.sleep(10)  # 模拟异步邮件发送
    logger.info(f"Sent email notification to user {user_id}: {message}")
    return {"status": "sent", "user_id": user_id, "message": message}


async def send_email_notification_fail() -> None:
    user_id = randint(1, 100)
    message = "This is a test email notification that may fail."
    await asyncio.sleep(10)  # 模拟异步邮件发送
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

## FastAPI 应用集成

在演示应用中，直接在 lifespan 中注册定时任务，并提供一个 API 用于动态添加临时任务。

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

    # 注册定时任务
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
    # 启动 4 个工作进程进行测试
    uvicorn.run("main:app", host="127.0.0.1", port=10001, workers=4)
```

## 运行测试

启动服务后，可以观察控制台日志确认任务是否出现重复执行问题。同时可以通过以下命令测试动态添加临时任务：

```bash
curl -X PUT 'http://127.0.0.1:10001/send_email_notification?user_id=1234&message=hello'
```

## 总结

通过本文的实现，我们成功构建了一个轻量级的异步定时任务调度器，有效解决了多进程环境下的任务重复执行问题。关键要点包括：

1. **分布式锁机制**：基于数据库唯一约束实现，确保同一任务在同一时间仅由一个工作进程执行。
2. **灵活的任务类型**：同时支持 Cron 定时任务和一次性临时任务。
3. **异步兼容性**：能够正确处理异步和同步任务函数。
4. **可扩展性**：基于 SQLAlchemy 的设计使得数据库迁移变得简单。

对于更复杂的场景，可以考虑以下改进方向：

- **任务持久化**：将任务注册信息持久化到数据库，支持动态任务管理。
- **任务监控**：提供 Web UI 或 API 用于监控任务状态和执行历史。
- **高可用性**：在微服务架构中，可以将调度器独立部署为专门的服务，通过远程调用执行任务。
- **任务队列**：对于耗时较长的任务，可以集成任务队列系统进行异步处理。

此外，关于任务函数的定义，也可以考虑使用面向对象的方式，定义抽象基类 `Job`，通过 `__init_subclass__()` 机制自动注册任务类，这样可以提供更好的类型安全性和代码组织结构。