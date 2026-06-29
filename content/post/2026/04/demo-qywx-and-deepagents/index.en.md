+++
date = '2026-04-15T00:09:04+08:00'
draft = false
title = 'Integrating Enterprise WeChat Bot with DeepAgents'
summary = 'Enterprise WeChat bot integration with DeepAgents for smart conversations'
isCJKLanguage = false
categories = ["program"]
tags = ["qywx", "deepagents", "python", "AI-Translated"]
keywords = ["qywx", "deepagents", "python"]
slug = 'demo-qywx-and-deepagents'
+++

## Introduction

Enterprise WeChat (WeCom) bots previously relied on Webhook callbacks for message receiving, which had limitations such as high latency and the need for a public server. Following the rise of OpenClaw, WeCom bots now support WebSocket persistent connections. This article presents a WeCom bot implementation based on WebSocket long connections, integrated with the DeepAgents framework for intelligent conversations.

## Tech Stack

- **WeCom WebSocket SDK**: `wecom-aibot-python-sdk` — official WebSocket connection library
- **FastAPI**: Modern async web framework for hosting services and MCP servers
- **DeepAgents**: Agent framework for building AI assistants with tool-calling capabilities
- **LangChain**: LLM integration and tool loading
- **MCP (Model Context Protocol)**: Standardized tool invocation protocol

## Project Structure

```
qywx-bot/
├── main.py                 # FastAPI entry point
├── pyproject.toml         # Project dependencies
├── conf/
│   └── config.toml        # Application config
├── pkg/
│   ├── config/            # Config management
│   ├── log/               # Logging module
│   └── qywx/              # WeCom client
└── ai_agent/
    ├── ai_agent.py        # DeepAgents integration
    └── mcp_servers/       # MCP tool servers
```

## Installing Dependencies

```shell
uv add fastapi deepagents langchain-openai langchain-mcp-adapters wecom-aibot-python-sdk uvicorn
```

## Core Implementation

### 1. Config Management

Manage configuration in TOML format, supporting multi-environment switching:

```toml
[service]
host = "127.0.0.1"
port = 8000
env = "dev"

[qywx.v2]
bot_id = "your-bot-id"
secret = "your-bot-secret"
bot_name = "智能助手"
```

### 2. WeCom WebSocket Client

Receive WeCom messages via WebSocket persistent connections for low-latency real-time interaction:

```python
class QywxClient:
    async def start(self):
        self.ws_client = WSClient(
            WSClientOptions(
                bot_id=cfg.qywx_bot_id,
                secret=cfg.qywx_secret,
                logger=self.logger,
            )
        )
        
        self.ws_client.on("authenticated", self._on_authenticated)
        self.ws_client.on("event.enter_chat", self._on_event_enter_chat)
        self.ws_client.on("message.text", self._on_message_text)
        
        await self.ws_client.connect()
```

### 3. DeepAgents Integration

Build an intelligent agent with tool-calling capabilities via the MCP protocol:

```python
class AIAgent:
    async def _create_root_agent(self, session: ClientSession):
        tools = await load_mcp_tools(session)
        return create_deep_agent(
            model=self.model,
            tools=tools,
            system_prompt=f"You are a WeCom bot named {cfg.qywx_bot_name}",
        )
```

### 4. Streaming Output

Implement WeCom streaming message replies for better user experience:

```python
async def _on_message_text(self, frame: WsFrameHeaders):
    stream_id = generate_req_id('stream')
    await self.ws_client.reply_stream(frame, stream_id, "Thinking...", False)
    
    async for chunk in aiops.invoke(content):
        await self.ws_client.reply_stream(frame, stream_id, str(chunk), False)
    
    await self.ws_client.reply_stream(frame, stream_id, "", True)
```

### 5. FastAPI Lifespan Management

Properly manage application lifecycle, including WebSocket connections, MCP servers, and AI agent:

```python
@asynccontextmanager
async def lifespan(app: FastAPI):
    await aiops.start()
    await qywx_client.start()
    
    mcp_app = datetime_mcp.streamable_http_app()
    async with datetime_mcp.session_manager.run():
        app.mount("/mcp", mcp_app)
        yield
    
    await aiops.shutdown()
    await qywx_client.shutdown()
```

## Key Technical Points

### Mounting MCP Server

When mounting a FastMCP server onto FastAPI, proper session manager initialization is crucial:

```python
# Wrong: directly mounting leads to uninitialized task group
app.mount("/mcp", datetime_mcp.streamable_http_app())

# Correct: start session manager in lifespan
async with datetime_mcp.session_manager.run():
    app.mount("/mcp", mcp_app)
    yield
```

### Streaming Message Parsing

DeepAgents' `astream()` returns nested dict chunks. Proper content extraction:

```python
async for chunk in root_agent.astream(input={"messages": [HumanMessage(content=input)]}):
    if isinstance(chunk, dict):
        messages = chunk.get("model", {}).get("messages", [])
        for msg in messages:
            if hasattr(msg, "content") and msg.content:
                yield str(msg.content)
```

## Example Code

Config and logging modules are omitted for brevity. MCP Server implementation is also skipped as it has been covered extensively in previous articles.

### QywxClient

`pkg/qywx/qywx_client.py` encapsulates WeCom bot interaction methods.

```python
from pkg.config import cfg
from pkg.log import get_logger
from aibot import WSClient, WSClientOptions, generate_req_id, WsFrameHeaders
from ai_agent import aiops
import logging

class QywxClient:
    logger = get_logger("qywx_client", logging.INFO)

    def __init__(self) -> None:
        self.ws_client: WSClient = None

    async def _on_authenticated(self):
        self.logger.info("Authenticated with Qywx server")

    async def _on_event_enter_chat(self, frame: WsFrameHeaders):
        self.logger.debug("Received event: enter_chat")
        await self.ws_client.reply_welcome(frame, {
            "msgtype": "text",
            "text": {'content': f'Hello! I am {cfg.qywx_bot_name}. How can I help you?'},
        })

    async def _on_message_text(self, frame: WsFrameHeaders):
        self.logger.debug("Received text message")
        msg_id = frame.get("body", {}).get("msgid", "")
        user_id = frame.get("body", {}).get("from", {}).get("userid", "")
        chattype = frame.get("body", {}).get("chattype", "")
        response_url = frame.get("body", {}).get("response_url", "")
        content = frame.get('body', {}).get('text', {}).get('content', '')
        self.logger.debug(f"Message content: {content}, from user: {user_id}")

        stream_id = generate_req_id('stream')

        await self.ws_client.reply_stream(frame, stream_id, "Brain thinking hard...", False)
        
        final_text = ""
        async for chunk in aiops.astream(input=content):
            await self.ws_client.reply_stream(frame, stream_id, chunk, False)
            final_text = chunk

        await self.ws_client.reply_stream(frame, stream_id, final_text, True)

    async def start(self):
        self.logger.info("Starting QywxClient...")
        if not self.ws_client:
            self.ws_client = WSClient(
                WSClientOptions(
                    bot_id=cfg.qywx_bot_id,
                    secret=cfg.qywx_secret,
                    logger=self.logger,
                )
            )

        self.ws_client.on("authenticated", self._on_authenticated)
        self.ws_client.on("event.enter_chat", self._on_event_enter_chat)
        self.ws_client.on("message.text", self._on_message_text)

        await self.ws_client.connect()

    async def shutdown(self):
        self.logger.info("Shutting down QywxClient...")
        if self.ws_client and self.ws_client.is_connected:
            self.ws_client.disconnect()
```

### AIAgent

AIAgent is an AI agent class for processing WeCom messages.

```python
from deepagents import create_deep_agent
from langchain_mcp_adapters.tools import load_mcp_tools
from langchain_openai import ChatOpenAI
from langchain_core.messages import HumanMessage
from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamable_http_client
from pkg.config import cfg
from pkg.log import get_logger

class AIAgent:
    logger = get_logger("ai_agent")
    def __init__(self):
        self.model: ChatOpenAI = None
        self._mcp_session: ClientSession = None
        self._mcp_server_url = f"http://127.0.0.1:{cfg.service_port}/mcp/"

    async def start(self):
        if not self.model:
            self.model = ChatOpenAI(
                base_url=cfg.agent_base_url,
                api_key=cfg.agent_api_key,
                model=cfg.agent_model,
            )

    async def shutdown(self):
        self.model = None

    async def _create_root_agent(self, session: ClientSession):
        tools = await load_mcp_tools(session)
        root_agent = create_deep_agent(
            model=self.model,
            tools=tools,
            system_prompt=f"You are an AI assistant named {cfg.qywx_bot_name}. Help users with various problems in a warm and positive tone. Format your answers with markdown.",
        )
        return root_agent

    async def astream(self, input: str, thread_id: str = ""):
        self.logger.debug(f"Connecting to mcp server: {self._mcp_server_url}")
        async with streamable_http_client(self._mcp_server_url) as (read, write, get_session_id):
            async with ClientSession(read, write) as session:
                await session.initialize()

                root_agent = await self._create_root_agent(session)

                async for chunk in root_agent.astream(
                    input={"messages": [HumanMessage(content=input)]}
                ):
                    if isinstance(chunk, dict):
                        messages = chunk.get("model", {}).get("messages", [])
                        if not messages:
                            continue
                        for msg in messages:
                            if hasattr(msg, "content") and msg.content:
                                yield str(msg.content)
                    elif hasattr(chunk, "content"):
                        yield str(chunk.content)
                    else:
                        yield str(chunk)

    async def ainvoke(self, input: str, thread_id: str = ""):
        self.logger.debug(f"Connecting to mcp server: {self._mcp_server_url}")
        async with streamable_http_client(self._mcp_server_url) as (read, write, get_session_id):
            async with ClientSession(read, write) as session:
                await session.initialize()

                root_agent = await self._create_root_agent(session)
                resp = await root_agent.ainvoke(
                    input={"messages": [HumanMessage(content=input)]}
                )
                return resp["messages"][-1].content
```

### main

```python
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
import uvicorn
from contextlib import asynccontextmanager
from pkg.qywx import qywx_client
from pkg.config import cfg
from ai_agent.mcp_servers.datetime_server import mcp as datetime_mcp
from ai_agent import aiops

@asynccontextmanager
async def lifespan(app: FastAPI):
    await aiops.start()
    await qywx_client.start()
    
    mcp_app = datetime_mcp.streamable_http_app()
    
    async with datetime_mcp.session_manager.run():
        app.mount("/mcp", mcp_app)
        yield
    
    await aiops.shutdown()
    await qywx_client.shutdown()


app = FastAPI(
    lifespan=lifespan
)


if __name__ == "__main__":
    uvicorn.run("main:app", host=cfg.service_host, port=cfg.service_port)
```
