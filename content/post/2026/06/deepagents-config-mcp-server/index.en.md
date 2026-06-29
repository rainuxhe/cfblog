+++
date = '2026-06-08T20:00:47+08:00'
draft = false
title = 'Deepagents - Configuring MCP Server'
description = 'Configuring MCP Server for Deepagents'
summary = 'Integrating external tools via MCP Server with DeepAgents'
isCJKLanguage = false
categories = [
    "program"
]
tags = [
    "deepagents",
    "python",
    "ai",
    "mcp",
    "AI-Translated"
]
keywords = [
    "deepagents",
    "python",
    "ai",
    "mcp",
]
slug = 'deepagents-config-mcp-server'
+++

## Introduction

An Agent needs tools to be useful — checking the time, calling APIs, managing a calendar. You can write local functions with LangChain's `@tool` decorator for the Agent to use, but if you also need to expose that tool via HTTP API for external clients, you'll want MCP.

This article documents the process of writing a datetime tool service with FastMCP in a real project, then integrating it into deepagents using `langchain-mcp-adapters`' `MultiServerMCPClient`.

Core dependencies:

```
fastmcp>=3.3.1                     # MCP server framework
langchain-mcp-adapters>=0.2.2      # MCP -> LangChain tool adapter
deepagents>=0.4.12
fastapi>=0.135.2
```

## MCP Tool vs Agent Tool

Why write a tool as an MCP server instead of just using the `@tool` decorator for a few LangChain tools?

The key difference is **who calls it**. If your tool is only used by the Agent internally — like an internal formatting function — LangChain's `@tool` is sufficient, simple and direct. But if you also need to expose this tool via HTTP API to external clients (another service, a frontend, or even Postman for debugging), you need MCP — it's a standard protocol, and any MCP-compatible client can connect and use it.

So the strategy in this project is: datetime tools are built as MCP servers since they may be called by other services later; purely internal helper tools continue using `@tool`. Walk on two legs, no one-size-fits-all approach.

## Writing an MCP Server with FastMCP

FastMCP is currently the easiest framework for writing MCP servers in Python. A time-tool server looks like this:

```python
from fastmcp import FastMCP
from fastmcp.server.middleware.error_handling import ErrorHandlingMiddleware
from mcp.types import ToolAnnotations

mcp = FastMCP(
    name="datetime_server",
    instructions="A server for datetime related operations",
)
mcp.add_middleware(
    ErrorHandlingMiddleware(
        include_traceback=True,
        transform_errors=True,
    )
)

@mcp.tool(annotations=ToolAnnotations(readOnlyHint=True))
async def get_time_info(dt_str: str = "") -> BasicTimeInfo:
    """Get basic time info from an input datetime string. Defaults to current UTC time if not provided."""
    ...

@mcp.tool(annotations=ToolAnnotations(readOnlyHint=True))
async def timezone_convert(utc_datetime: str, target_timezone: str) -> str:
    """Convert UTC time to a specified timezone"""
    ...

@mcp.tool(annotations=ToolAnnotations(readOnlyHint=True))
async def datetime_diff(dt_str1: str, dt_str2: str) -> DatetimeDiff:
    """Calculate time difference between two ISO format datetime strings"""
    ...
```

A few notable points:

- **`ToolAnnotations(readOnlyHint=True)`**: Tells the caller these tools are read-only with no side effects. This helps with LLM reasoning — the model can safely call them. If your tool writes data (like creating a calendar event), don't add this annotation.
- **`ErrorHandlingMiddleware`**: Without it, MCP server returns a bare error code when a tool fails, making debugging nearly impossible. With `include_traceback` and `transform_errors` enabled, error messages include a traceback returned to the client, greatly simplifying troubleshooting.
- **Pydantic models as return values**: `BasicTimeInfo`, `DatetimeDiff`, etc., defined as Pydantic models, provide type safety and automatically generate schema descriptions in the MCP protocol layer, so the Agent understands what each field means.

## MultiServerMCPClient: Loading Tools from MCP

Now that the MCP server is written with FastMCP, how do we make deepagents use these tools? Use `MultiServerMCPClient` from `langchain-mcp-adapters`.

It's essentially a multi-server client manager — you tell it each MCP server's address and transport method, and it handles connection establishment, tool discovery, and conversion into LangChain's standard `BaseTool` list:

```python
from langchain_mcp_adapters.client import MultiServerMCPClient

client = MultiServerMCPClient(
    {
        "datetime": {
            "transport": "streamable_http",
            "url": "http://127.0.0.1:3002/api/mcp/datetime",
        }
    }
)

tools = await client.get_tools()
# tools is list[BaseTool], ready to feed into create_deep_agent()
```

The `transport` parameter currently supports two main options: `streamable_http` (suitable for network calls, cross-process sharing) and `stdio` (suitable for local subprocesses, single-machine deployment). This project uses the former since the MCP server is mounted as a FastAPI sub-app, not dependent on inter-process pipes.

For remote MCP servers requiring authentication, just add `headers`:

```python
{
    "didatick": {
        "transport": "streamable_http",
        "url": "https://mcp.dida365.com",
        "headers": {
            "Authorization": f"Bearer {cfg.DIDA_TOKEN}",
        },
    }
}
```

## Why a Separate MCPServers Class

The project doesn't put `MultiServerMCPClient` directly inside `AIAgent`. Instead, it's extracted into a separate `MCPServers` class:

```python
class MCPServers:
    def __init__(self):
        self._client_datetime: MultiServerMCPClient = None
        self._datetime_tools: list[BaseTool] = []
        self._client_didatick: MultiServerMCPClient = None
        self._didatick_tools: list[BaseTool] = []

    async def get_datetime_tools(self) -> list[BaseTool]:
        if not self._datetime_tools:
            await self._init_datetime_mcp()
        return self._datetime_tools

    async def get_didatick_tools(self) -> list[BaseTool]:
        if not self._didatick_tools:
            await self._init_aididatick_mcp()
        return self._didatick_tools
```

The reasoning is simple: **SubAgents may only need a subset of MCP tools**. If your application has multiple SubAgents — one only checks calendars, another only checks time — letting each SubAgent receive only the tools it needs avoids "tool overload" where LLMs struggle to choose from too many tools.

Each MCP server's tools are independently exposed via `get_xxx_tools()`, allowing flexible composition at the upper layer:

```python
class AIAgent:
    def __init__(self):
        self._mcp_servers = MCPServers()

    async def _init_tools(self):
        tools_mcp_datetime = await self._mcp_servers.get_datetime_tools()
        tools_mcp_didatick = await self._mcp_servers.get_didatick_tools()
        self._tools.extend(tools_mcp_datetime)
        self._tools.extend(tools_mcp_didatick)
```

Additionally, the lazy loading + caching pattern ensures each MCP server is connected only once.

## Mounting FastMCP in FastAPI

FastMCP has built-in ASGI app generation. Just feed it to FastAPI's `mount()`. But there's a detail: lifespan management.

FastMCP has its own lifespan logic (registering tool schemas, HTTP handlers, etc.), and FastAPI has its own lifespan (database connection pool initialization, etc.). If you just call `app.mount()`, FastAPI won't automatically manage the sub-app's lifespan, potentially causing startup ordering issues.

The solution is `fastmcp.utilities.lifespan.combine_lifespans`:

```python
from fastmcp.utilities.lifespan import combine_lifespans

def create_app() -> FastAPI:
    datetime_mcp_app = datetime_mcp.http_app(path="/datetime")

    app = FastAPI(lifespan=combine_lifespans(lifespan, datetime_mcp_app.lifespan))

    app.mount("/api/mcp", datetime_mcp_app)

    return app
```

The actual access path becomes `/api/mcp/datetime` — `app.mount`'s `/api/mcp` is the prefix, and `http_app(path="/datetime")`'s `/datetime` is the sub-path.

If your project mounts multiple MCP servers, call `http_app(path="...")` for each and mount them individually — don't forget to include all their lifespans in `combine_lifespans`.

Finally, since the MCP client connects to a server within the same process, use `127.0.0.1` as the endpoint:

```python
endpoint = f"http://127.0.0.1:{cfg.SERVER_PORT}/api/mcp/datetime"
```

## Agent-Side Integration

`create_deep_agent()` accepts a tool list — whether the tools are local `@tool` functions or loaded from MCP, it treats them the same:

```python
class AIAgent:
    async def _init_deep_agent(self):
        if self._agent:
            return

        if not self._tools:
            await self._init_tools()

        self._agent = create_deep_agent(
            model=self._llm,
            tools=self._tools,
            checkpointer=checkpointer,
            system_prompt="...",
            middleware=[
                ToolRetryMiddleware(
                    max_retries=2,
                    retry_on=(TimeoutException,),
                    on_failure="continue",
                )
            ],
        )
```

`ToolRetryMiddleware` serves two purposes here:

- **`max_retries=2`**: MCP tools go through HTTP, where network jitter or temporary server unavailability can occur. Two retries prevent a single hiccup from breaking the entire flow.
- **`on_failure="continue"`**: When retries are exhausted and still fail, `continue` tells the Agent not to stop but to pass the failure information back to the LLM. For example, if the AI passes wrong parameters and the tool throws `ValidationError`, `ToolRetryMiddleware` feeds the error back to the LLM, which can then correct the parameters and retry. This is much more practical than crashing outright. You can also set it to `raise` if you prefer exceptions to propagate.

## Improvements

- **Independent MCP server deployment**: Currently, `datetime_mcp` runs as a FastAPI sub-app in the same process as the Agent. If the server is heavy (e.g., a vision tool requiring GPU inference), it should be deployed separately with the client connecting via remote HTTP.
- **Tool name conflicts across servers**: If two MCP servers happen to provide tools with the same name, `MultiServerMCPClient.get_tools()`'s behavior depends on implementation — it might overwrite or throw errors. It's best to design each server's tools with meaningful prefixes or namespaces.
- **streamable_http vs stdio**: `streamable_http` is convenient for debugging (you can curl the MCP server directly). `stdio` has a hidden pitfall — if each Agent request creates a new MCP connection (using `MultiServerMCPClient`'s `connect()` / `disconnect()` pattern), a bunch of MCP server subprocesses accumulate in the background. If you create long-lived connections upfront, you have to manage their lifecycle yourself. In this project, the Agent calls its own in-process MCP API over `127.0.0.1`, adding only local network stack overhead — actual latency is negligible unless tool call volume is extremely high.
- **Authentication**: Remote MCP servers currently pass Bearer tokens via headers. In production, if tokens have expiration policies, add token refresh and retry logic to avoid failing on 401 during connection initialization.
- MCP server configuration should be externalized to a config file for dynamic management.
