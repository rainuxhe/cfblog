+++
date = '2026-05-31T00:08:19+08:00'
draft = false
title = 'Using Argparse in a Chatbot'
description = 'Argparse in Chatbot'
summary = 'Using argparse for chat command parsing'
isCJKLanguage = false
categories = ["program"]
tags = ["python", "AI-Translated"]
keywords = ["python", "argparse", "chatbot"]
slug = 'argparse-in-chatbot'
+++

## Introduction

When developing an AI-driven IM bot, some scenarios are better handled with commands — they're faster and more precise. My idea is to split the user's input text by spaces, take the first token, and match it against a command dictionary. If it matches, the user wants to execute a command; pass it to the command handler. If it doesn't match, the user is sending natural language, which should be routed to AI modules.

I mentioned how to handle commands in a previous blog post about `__init_subclass__()`, but that approach only supported simple command formats where the text is split by spaces without `--xx` style parameters. While pondering how to handle these different parameter formats, I suddenly remembered Python's standard library `argparse`. Why not use `argparse` directly — it'd be much more convenient! After briefly reviewing the `argparse` docs and source code, it seemed feasible. Let's do it!

## Flow Logic

Here's a brief description of the flow:

1. User sends a message via HTTP API `/api/chat`
2. The backend splits the input text by spaces and takes the first token
3. Matches against the command dictionary. If no match, treat as natural language
4. If matched, hand it to the command handler class. The command class creates an argument parser to parse parameters
5. Return results to the user

According to convention, specific command classes are dynamically loaded without needing to import them individually. This way, adding new commands later only requires adding a code file in the specified directory and developing the command class following the specification.

This article focuses on how to use `argparse` to parse user commands in a web application. It does not include AI-related natural language processing. Therefore, the only third-party dependency used is FastAPI as the HTTP framework — it could be replaced with Flask or any other framework.

## Code Implementation

Code structure:

```
├── internal
│   └── cmd
│       ├── admin.py
│       ├── base.py
│       ├── demo.py
│       └── __init__.py
├── main.py
├── pyproject.toml
└── README.md
```

### Core Abstractions: ChatArgparser and ChatCommand

`argparse` is designed for command-line tools. Its default behavior on parsing errors is to print an error message and exit the process — clearly unsuitable for web applications. So we need to subclass `argparse.ArgumentParser` and override its `error()`, `exit()`, and `print_help()` methods, turning "exit process" into "raise exception." This way, the exception is caught by the upper layer and returned as an HTTP response.

`ChatArgparser` does three things:

- Override `error()`: Instead of calling `sys.exit()`, log the error and raise `argparse.ArgumentError`.
- Override `exit()`: `argparse` calls `exit()` when the user enters `--help`. Change it to raise an exception, attaching the help text to the error message.
- Override `print_help()`: Output help text to a `StringIO` buffer for later use.

```python
class ChatArgparser(argparse.ArgumentParser):
    def error(self, message):
        self.parse_error_triggered = True
        self.error_message = message
        raise argparse.ArgumentError(None, message)

    def exit(self, status=0, message=None):
        self.parse_error_triggered = True
        if self.help_text:
            self.error_message = f"Help requested:\n{self.help_text}"
        elif message:
            self.error_message = message
        raise argparse.ArgumentError(None, self.error_message)
```

`ChatCommand` is the abstract base class for all commands. It defines two interfaces: `create_parser()` returns a `ChatArgparser` instance declaring the command's accepted parameters; `run()` is an async method that executes the actual command logic.

### Command Loading: Auto-Discovery and Registration

The `load_chat_commands()` function scans all modules under the `internal.cmd` package, finds classes inheriting from `ChatCommand`, and decides whether to register them based on class attributes `main_name`, `is_enable`, and `is_visible`.

It skips the `base` and `__init__` modules to avoid registering the base class or itself. Each command class needs to define several class attributes:

- `main_name`: Command name, starting with `/`, e.g., `/demo`.
- `description`: Brief command description.
- `is_enable`: Whether the command is enabled. Disabled commands won't be registered.
- `is_visible`: Whether to show in the help list, suitable for hiding admin commands.

`HelpCommand` is the built-in help command that iterates through all registered visible commands and returns the help information.

```python
class HelpCommand(ChatCommand):
    main_name: str = "/help"
    description: str = "Show help message for all commands"
    is_visible: bool = True

    async def run(self) -> str:
        help_message = "Available commands:\n"
        for main_name, info in _loaded_chat_commands.items():
            if info["is_visible"]:
                help_message += f"{main_name}: {info['description']}\n"
        return help_message
```

### Example Command

Take `DemoCommand` as an example. It accepts `--name` and `--age` parameters. In `run()`, first use `shlex.split()` to split the user message by shell syntax into a list, remove the first element (the command itself), then pass the remaining arguments to `ChatArgparser` for parsing.

`shlex.split()` is used instead of `str.split()` because users may wrap parameter values with spaces in quotes within IM input, and `shlex.split()` handles this correctly.

```python
class DemoCommand(ChatCommand):
    main_name: str = "/demo"
    description: str = "Demo command for testing"
    is_enable: bool = True
    is_visible: bool = True

    async def run(self) -> str:
        cmd_args = shlex.split(self.user_message)[1:]
        parsed_args = self.arg_parser.parse_args(cmd_args)
        return f"Hello, {parsed_args.name}! You are {parsed_args.age} years old."

    def create_parser(self) -> ChatArgparser:
        parser = ChatArgparser(prog="demo", description=self.description)
        parser.add_argument("--name", type=str, help="Name of the user")
        parser.add_argument("--age", type=int, help="Age of the user")
        return parser
```

`AdminCommand` has a similar structure, except `is_visible = False`, so it won't appear in `/help` output. Only administrators who know the specific command can use it.

### HTTP Endpoint: /api/chat

The `/api/chat` endpoint in `main.py` receives user messages. The processing flow is:

1. Use `strip().split(" ")` to get the first word and check if it starts with `/`.
2. If it doesn't start with `/`, treat as natural language and return directly (AI handling is beyond this article's scope).
3. If it starts with `/`, call `load_chat_commands()` to find the matching command. If not found, treat as natural language.
4. If found, instantiate the command class and call `run()` to execute.
5. The entire flow is wrapped in `try/except`, catching `argparse.ArgumentError` — if the error message starts with `"Help requested:"`, the user entered `--help`, so return the help text; otherwise, return a parsing error prompt.

```python
@app.post("/api/chat")
async def post_chat(req: RequestChat):
    msg_list = req.message.strip().split(" ")
    if not msg_list[0].startswith("/"):
        return {"info": "Natural language, expected to be handled by AI"}

    cmders = load_chat_commands()
    if msg_list[0] not in cmders:
        return {"info": "Unknown command, expected to be handled by AI"}

    cmd_cls = cmders[msg_list[0]]["cmdcls"]
    cmd_instance = cmd_cls(req.message)
    rst = await cmd_instance.run()
    return {"result": rst}
```

### Actual Results

*The output can be prettified in real applications.*

1. Send `/help` to get available commands. Since `/admin` is set to invisible, it won't appear.

```shell
curl --request POST \
  --url http://127.0.0.1:10001/api/chat \
  --header 'content-type: application/json' \
  --data '{
  "session_id": "qwerasd",
  "message": "/help"
}'

# Response
{
  "session_id": "qwerasd",
  "result": "Available commands:\n/demo: Demo command for testing\n/help: Show help message for all commands\n"
}
```

2. User sends `/demo --help`

```shell
curl --request POST \
  --url http://127.0.0.1:10001/api/chat \
  --header 'content-type: application/json' \
  --data '{
  "session_id": "qwerasd",
  "message": "/demo --help"
}'

# Response
{
  "session_id": "qwerasd",
  "result": "Help requested:\nusage: demo [-h] [--name NAME] [--age AGE]\n\nDemo command for testing\n\noptions:\n  -h, --help   show this help message and exit\n  --name NAME  Name of the user\n  --age AGE    Age of the user\n"
}
```

3. User sends `/admin --host 192.168.1.1 --port=12345`

```shell
curl --request POST \
  --url http://127.0.0.1:10001/api/chat \
  --header 'content-type: application/json' \
  --data '{
  "session_id": "qwerasd",
  "message": "/admin --host 192.168.1.1 --port=12345"
}'

# Response
{
  "session_id": "qwerasd",
  "result": "Admin command executed! Host: 192.168.1.1, Port: 12345"
}
```

## Improvements

- Command class enable/visible status should be configured externally, or support dynamic configuration.
- Real applications should add permission control.
- The dynamic command loading approach has some magic to it; if there aren't many commands, you can import them manually.

## Complete Example Code

### `internal/cmd/base.py`

```python
import argparse
from abc import ABC, abstractmethod
from io import StringIO


class ChatArgparser(argparse.ArgumentParser):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.parse_error_triggered = False
        self.error_message = ""
        self.help_text = ""

    def print_help(self, file=None):
        help_buffer = StringIO()
        super().print_help(help_buffer)
        self.help_text = help_buffer.getvalue()

    def error(self, message):
        self.parse_error_triggered = True
        self.error_message = message
        raise argparse.ArgumentError(None, message)

    def exit(self, status=0, message=None):
        self.parse_error_triggered = True
        if self.help_text:
            self.error_message = f"Help requested:\n{self.help_text}"
        elif message:
            self.error_message = message
        else:
            self.error_message = "Exit triggered without message"
        raise argparse.ArgumentError(None, self.error_message)


class ChatCommand(ABC):
    def __init__(self, user_message: str):
        self.user_message = user_message

    @abstractmethod
    def create_parser(self) -> ChatArgparser:
        ...

    @abstractmethod
    async def run(self) -> str:
        ...
```

### `internal/cmd/demo.py`

```python
import argparse
import shlex

from internal.cmd.base import ChatArgparser, ChatCommand


class DemoCommand(ChatCommand):
    main_name: str = "/demo"
    description: str = "Demo command for testing"
    is_enable: bool = True
    is_visible: bool = True

    def __init__(self, user_message: str):
        super().__init__(user_message)
        self.arg_parser = self.create_parser()

    async def run(self) -> str:
        try:
            cmd_args = shlex.split(self.user_message)[1:]
        except ValueError as e:
            return f"shlex parsing error: {str(e)}"

        try:
            parsed_args = self.arg_parser.parse_args(cmd_args)
            return f"Hello, {parsed_args.name}! You are {parsed_args.age} years old."
        except argparse.ArgumentError as e:
            error_msg = str(e)
            if error_msg.startswith("Help requested:"):
                return error_msg
            return f"Parser error: {str(e)}"

    def create_parser(self) -> ChatArgparser:
        parser = ChatArgparser(prog="demo", description=self.description)

        parser.add_argument("--name", type=str, help="Name of the user")
        parser.add_argument("--age", type=int, help="Age of the user")
        return parser
```

### `internal/cmd/admin.py`

```python
import argparse
import shlex

from internal.cmd.base import ChatArgparser, ChatCommand


class AdminCommand(ChatCommand):
    main_name: str = "/admin"
    description: str = "Admin command"
    is_enable: bool = True
    is_visible: bool = False

    def __init__(self, user_message: str):
        super().__init__(user_message)
        self.arg_parser = self.create_parser()

    async def run(self) -> str:
        try:
            cmd_args = shlex.split(self.user_message)[1:]
        except ValueError as e:
            return f"shlex parsing error: {str(e)}"

        try:
            parsed_args = self.arg_parser.parse_args(cmd_args)
            return f"Admin command executed! Host: {parsed_args.host}, Port: {parsed_args.port}"
        except argparse.ArgumentError as e:
            error_msg = str(e)
            if error_msg.startswith("Help requested:"):
                return error_msg
            return f"Parser error: {str(e)}"

    def create_parser(self) -> ChatArgparser:
        parser = ChatArgparser(prog="admin", description=self.description)

        parser.add_argument("--host", type=str, help="Hostname or IP address")
        parser.add_argument("--port", type=int, help="Port number")
        return parser
```

### `internal/cmd/__init__.py`

```python
from __future__ import annotations

import importlib
import pkgutil
from typing import Dict, TypedDict

from .base import ChatArgparser, ChatCommand


class CommandInfo(TypedDict):
    description: str
    cmdcls: type[ChatCommand]
    is_visible: bool


_loaded_chat_commands: Dict[str, CommandInfo] = {}


class HelpCommand(ChatCommand):
    main_name: str = "/help"
    description: str = "Show help message for all commands"
    is_visible: bool = True

    def create_parser(self) -> ChatArgparser:
        return ChatArgparser(
            prog="help", description="Show help message for all commands"
        )

    async def run(self) -> str:
        if not _loaded_chat_commands:
            load_chat_commands()

        help_message = "Available commands:\n"
        for main_name, info in _loaded_chat_commands.items():
            if info["is_visible"]:
                help_message += f"{main_name}: {info['description']}\n"
        return help_message


def load_chat_commands() -> Dict[str, CommandInfo]:
    if _loaded_chat_commands:
        return _loaded_chat_commands

    pkg_path = "internal.cmd"
    pkg = importlib.import_module(pkg_path)
    print(f"Loading chat commands from package: {pkg_path}")

    for _, name, ispkg in pkgutil.iter_modules(pkg.__path__, pkg.__name__ + "."):
        if ispkg:
            continue
        skipped_modules = {"base", "__init__"}
        if any(name.endswith(skiped) for skiped in skipped_modules):
            continue
        module = importlib.import_module(name)
        for attr_name in dir(module):
            attr = getattr(module, attr_name)
            if (
                isinstance(attr, type)
                and issubclass(attr, ChatCommand)
                and attr is not ChatCommand
            ):
                main_name = getattr(attr, "main_name", None)
                description = getattr(attr, "description", None)
                is_enable = getattr(attr, "is_enable", False)
                is_visible = getattr(attr, "is_visible", True)
                if not main_name or not description:
                    continue
                if not is_enable:
                    continue
                main_name = main_name.strip()
                description = description.strip()
                if main_name.startswith("/") and main_name not in _loaded_chat_commands:
                    _loaded_chat_commands[main_name] = {
                        "description": description,
                        "cmdcls": attr,
                        "is_visible": is_visible,
                    }

    if "/help" not in _loaded_chat_commands:
        _loaded_chat_commands["/help"] = {
            "description": HelpCommand.description,
            "cmdcls": HelpCommand,
            "is_visible": True,
        }

    return _loaded_chat_commands

```

### `main.py`

```python
import argparse
from contextlib import asynccontextmanager

import uvicorn
from fastapi import FastAPI
from pydantic import BaseModel, Field, ValidationInfo, field_validator

from internal.cmd import load_chat_commands


class RequestChat(BaseModel):
    session_id: str = Field(
        ..., min_length=1, description="Unique identifier for the chat session"
    )
    message: str = Field(
        ..., min_length=1, description="The chat message sent by the user"
    )

    @field_validator("session_id", "message")
    @classmethod
    def validate_fields(cls, v: str, info: ValidationInfo) -> str:
        if not v or not v.strip():
            raise ValueError(f"Field '{info.field_name}' cannot be empty")
        return v.strip()


@asynccontextmanager
async def lifespan(app: FastAPI):
    print("Starting up...")
    try:
        yield
    finally:
        print("Shutting down...")


app = FastAPI(lifespan=lifespan)


@app.post("/api/chat")
async def post_chat(req: RequestChat):
    try:
        msg_list = req.message.strip().split(" ")
        if not msg_list[0].startswith("/"):
            return {
                "session_id": req.session_id,
                "message": req.message,
                "info": "Natural language, expected to be handled by AI",
            }

        cmders = load_chat_commands()
        if msg_list[0] not in cmders:
            return {
                "session_id": req.session_id,
                "message": req.message,
                "info": "Unknown command, expected to be handled by AI",
            }

        cmd_cls = cmders[msg_list[0]]["cmdcls"]
        cmd_instance = cmd_cls(req.message)
        rst = await cmd_instance.run()
        return {"session_id": req.session_id, "result": rst}

    except argparse.ArgumentError as e:
        error_msg = str(e)
        if error_msg.startswith("Help requested:"):
            return {"session_id": req.session_id, "result": error_msg}
        return {"session_id": req.session_id, "message": f"Parse error: {str(e)}"}
    except Exception as e:
        return {"session_id": req.session_id, "message": f"Parse error: {str(e)}"}


if __name__ == "__main__":
    uvicorn.run("main:app", host="127.0.0.1", port=10001, workers=1)

```
