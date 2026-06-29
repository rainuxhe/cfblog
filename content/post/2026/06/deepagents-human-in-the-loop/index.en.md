+++
date = '2026-06-14T20:02:30+08:00'
draft = false
title = 'Deepagents - Human in the Loop'
description = 'Deepagents Human in the Loop'
summary = 'Human approval workflow with DeepAgents'
isCJKLanguage = false
categories = ["program"]
tags = ["deepagents", "python", "ai", "AI-Translated"]
keywords = ["deepagents", "python", "ai"]
slug = 'deepagents-human-in-the-loop'
+++

## Introduction

Human in the Loop (HITL) is critical in enterprise-grade Agent applications — AI must get human approval before executing critical tools to prevent operational mistakes. I previously implemented this from scratch with LangGraph 0.3, manually calling `interrupt()` inside tool functions — very verbose. Now with DeepAgents and the built-in `HumanInTheLoopMiddleware`, just configure an `interrupt_on` dict and the interruption logic is fully automatic — pausing graph execution before the tool runs, saving state to the checkpointer, and waiting for human decisions to resume.

However, the official documentation's example code is fairly simple, only demonstrating basic usage without explaining how to integrate it into a real application. This article walks through a complete HITL flow based on the requirement "allow the AI to execute shell commands, but require user confirmation before each execution."

### Core Concepts

Before we begin, let's clarify a few key concepts:

| Concept | Description |
|---------|-------------|
| **interrupt** | When the Agent is about to call a monitored tool, `HumanInTheLoopMiddleware` calls LangGraph's `interrupt()` to pause graph execution, raising a request containing `action_requests` and `review_configs` |
| **checkpoint** | Graph state is persisted at interruption. **A checkpointer is mandatory** — without it, execution cannot resume after interruption. Use `AsyncPostgresSaver` in production, `InMemorySaver` for testing |
| **`version="v2"`** | LangGraph 1.0's v2 mode: `ainvoke()` returns a `GraphOutput` object (with `.interrupts` attribute), and `astream()`'s `updates` stream contains `__interrupt__` events |
| **Command(resume=)** | After the user makes a decision, resume execution from the breakpoint using `Command(resume={"decisions": [...]})` |
| **Decision** | Four types: `approve`, `reject` (with feedback), `edit` (modify parameters and execute), `respond` (human responds directly, skipping tool execution) |

### Execution Lifecycle

```plain
User asks → Agent calls LLM for response
  → LLM decides to call a tool (e.g., execute_shell_command)
    → after_model hook: checks if the tool is in interrupt_on
      → Yes: builds HITLRequest → interrupt() → paused ⌛
      → No: continues execution
  → Human makes a decision (approve / reject / edit / respond)
    → Resumes execution → executes/denies tool → LLM generates final response → returns
```

## Flow Logic

Using Chainlit as the chat interaction medium, the message processing flow is as follows:

1. User sends a message in the chat interface (e.g., "Check system load")
2. Agent calls LLM to generate a response; LLM decides to call `execute_shell_command`
3. `HumanInTheLoopMiddleware` detects this tool is in the `interrupt_on` list, triggers an interrupt
4. Chainlit detects the interrupt and displays an approval prompt to the user
5. User replies with "Approve" / "Reject"; the app uses `Command(resume=)` to resume execution
6. Agent executes or denies the tool based on the decision, finally returning the result to the user

## Configuring Interruption

First, configure `HumanInTheLoopMiddleware` when creating the Agent:

```python
from deepagents import create_deep_agent
from langchain.agents.middleware import HumanInTheLoopMiddleware

agent = create_deep_agent(
    model=llm,
    tools=[execute_shell_command],
    checkpointer=checkpointer,  # Required!
    system_prompt="You are a helpful assistant...",
    middleware=[
        HumanInTheLoopMiddleware(
            interrupt_on={
                "execute_shell_command": {
                    "allowed_decisions": ["approve", "reject"]
                }
            }
        ),
    ],
)
```

`interrupt_on` is a dict where keys are tool names. Value options:

- `True` — Allow all four decision types (approve / edit / reject / respond)
- `False` — Don't intercept this tool (equivalent to omitting it)
- `{"allowed_decisions": [...]}` — Only allow specified decision types
- Additional options: `when` predicate for conditional interception based on parameters, `description` for custom interrupt prompt text

## Implementation in invoke Mode

In v2 mode, `ainvoke()` returns a `GraphOutput` object. Use the `.interrupts` attribute to directly get interrupt data without querying state.

### Detecting Interrupts

```python
resp = await agent.ainvoke(
    input={"messages": [HumanMessage(content=query)]},
    config=config,
    version="v2",
)

if resp.interrupts:
    interrupt = resp.interrupts[0]
    print(interrupt.value["action_requests"])
```

### Resuming Interrupts

After the user makes a decision, resume with `Command(resume=)`:

```python
from langgraph.types import Command

await agent.ainvoke(
    Command(resume={
        "decisions": [{"type": "approve"}]
    }),
    config=config,
    version="v2",
)
```

### Key Challenge: Differentiating "New Message" from "Interrupt Resume"

In a chat application, every user message goes through the same `@cl.on_message` handler. Both "check the load" and "approve" are just text. The solution is — **check for pending interrupts before invoking**:

```python
state = await agent.aget_state(config)
if state.next:
    # Pending interrupt → this message is an approval reply
    cmd = Command(resume={"decisions": [{"type": "approve"}]})
    await agent.ainvoke(cmd, config=config, version="v2")
else:
    # No interrupt → normal conversation
    resp = await agent.ainvoke(
        {"messages": [HumanMessage(content=query)]}, config=config, version="v2"
    )
```

A non-empty `state.next` means graph execution is paused (an interrupt is waiting).

## Implementation in stream Mode

Streaming mode requires `stream_mode=["messages", "updates"]` (the official recommendation to enable both):

- `messages` stream: Gets LLM token-level output
- `updates` stream: Detects interrupt events `__interrupt__`

```python
async for chunk in agent.astream(
    input=input_data,
    stream_mode=["messages", "updates"],
    version="v2",
    config=config,
):
    if chunk["type"] == "messages":
        msg, _meta = chunk["data"]
        if isinstance(msg, AIMessageChunk) and msg.content:
            yield extract_text(msg)
    elif chunk["type"] == "updates":
        if "__interrupt__" in chunk["data"]:
            interrupt = chunk["data"]["__interrupt__"][0]
            yield format_question(interrupt)
```

Stream mode resume is similar to invoke — check `state.next` before calling `astream()` to determine if it's a normal conversation or interrupt resume.

## Complete Example

> Below is the core code. Non-core code like `checkpointer` and `llm` configuration functions, logging modules, etc. are omitted.

### Agent Wrapper (`internal/agent/agent.py` core section)

```python
_APPROVE_KEYWORDS = frozenset(
    {"yes", "accept", "approve", "ok", "是", "允许", "同意", "批准"}
)

def _parse_decision(query: str) -> str:
    return "approve" if query.strip().lower() in _APPROVE_KEYWORDS else "reject"

def _build_resume_command(decision_type: str, actions_count: int) -> Command:
    item = {"type": decision_type}
    if decision_type == "reject":
        item["message"] = "user rejected this action"
    return Command(resume={"decisions": [item for _ in range(actions_count)]})

def _extract_text(message) -> str:
    if not message or not hasattr(message, "content"):
        return ""
    content = message.content
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "".join(
            b.get("text", "")
            for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""

def _format_interrupt_question(interrupt) -> str:
    action_requests = interrupt.value.get("action_requests", [])
    review_configs = interrupt.value.get("review_configs", [])
    allowed = (
        review_configs[0].get("allowed_decisions", ["approve", "reject"])
        if review_configs
        else ["approve", "reject"]
    )

    lines = []
    for req in action_requests:
        lines.append(
            "Do you approve me to execute this action?\n\n"
            f"- name: {req['name']}\n"
            f"- args: `{req['args']}`\n"
        )
    lines.append(f"Input your decision: {', '.join(allowed)}\n")
    return "\n".join(lines)


class AIAgent:
    async def _has_pending_interrupt(self, config: RunnableConfig) -> bool:
        state = await self._agent.aget_state(config)
        return bool(state.next)

    # --- invoke mode ---
    async def ainvoke(self, query: str, config: RunnableConfig) -> str:
        if not self._agent:
            await self._init_deep_agent()

        if await self._has_pending_interrupt(config):
            state = await self._agent.aget_state(config)
            actions_count = len(
                state.interrupts[0].value["action_requests"]
            )
            decision = _parse_decision(query)
            cmd = _build_resume_command(decision, actions_count)
            await self._agent.ainvoke(cmd, config=config, version="v2")

            state = await self._agent.aget_state(config)
            if state.values and "messages" in state.values:
                return _extract_text(state.values["messages"][-1])
            return "Oops, something went wrong."

        resp = await self._agent.ainvoke(
            input={"messages": [HumanMessage(content=query)]},
            config=config,
            version="v2",
        )
        if resp.interrupts:
            return _format_interrupt_question(resp.interrupts[0])
        return _extract_text(resp.value["messages"][-1])

    # --- stream mode ---
    async def astream(self, query: str, config: RunnableConfig):
        if not self._agent:
            await self._init_deep_agent()

        state = await self._agent.aget_state(config)
        if state.next:
            actions_count = len(
                state.interrupts[0].value["action_requests"]
            )
            decision = _parse_decision(query)
            input_data = _build_resume_command(decision, actions_count)
        else:
            input_data = {"messages": [HumanMessage(content=query)]}

        async for chunk in self._agent.astream(
            input=input_data,
            stream_mode=["messages", "updates"],
            version="v2",
            config=config,
        ):
            if chunk["type"] == "messages":
                msg, _meta = chunk["data"]
                if isinstance(msg, AIMessageChunk) and msg.content:
                    yield _extract_text(msg)
            elif chunk["type"] == "updates" and "__interrupt__" in chunk["data"]:
                yield _format_interrupt_question(
                    chunk["data"]["__interrupt__"][0]
                )
```

### Chainlit Application Layer (`chainlit_app.py` core section)

```python
@cl.on_message
async def main(msg: cl.Message):
    config = RunnableConfig(
        configurable={"thread_id": cl.context.session.id},
    )

    final_answer = cl.Message(content="")
    async for chunk in ai_agent.astream(msg.content, config=config):
        await final_answer.stream_token(chunk)
    await final_answer.send()
```

The Chainlit application layer is very concise — because interrupt detection and resume logic are all encapsulated inside `AIAgent`. Chainlit only needs to stream the output from `astream()` / `ainvoke()`.

### Interaction Flow

```plain
[User]: Check the system load

[AI]: 🔧 Calling tool: execute_shell_command...

[AI]: Do you approve me to execute this action?

       - name: execute_shell_command
       - args: `{"command": "cat /proc/loadavg && free -h", "timeout": 10}`

       Input your decision: approve, reject

[User]: approve

[AI]: Current system load: 0.52 0.38 0.25,
      Total memory: 62Gi, Used: 10Gi, Free: 46Gi, system running normally.
```

## Advanced: Using the interrupt_on when Predicate

If you don't want to intercept all shell commands but only dangerous ones (like `rm`, `dd`, writing to system directories, etc.), use the `when` predicate for conditional interception:

```python
from langgraph.prebuilt.tool_node import ToolCallRequest

def is_dangerous_command(request: ToolCallRequest) -> bool:
    command = request.tool_call["args"].get("command", "")
    dangerous = {"rm ", "dd ", "mkfs", "shutdown", "reboot"}
    return any(d in command for d in dangerous)

HumanInTheLoopMiddleware(
    interrupt_on={
        "execute_shell_command": {
            "allowed_decisions": ["approve", "reject"],
            "when": is_dangerous_command,
        }
    }
)
```

The `when` predicate only triggers interruption if it returns `True`. Returns `False` for automatic approval. Note that `when` requires `langchain >= 1.3.3`.

## Improvements

- Currently, reject uses a fixed message. In production, allow users to input a reason for rejection, helping the LLM adjust subsequent behavior.
- The approval prompt is plain text. Chainlit's `AskActionMessage` can create button-style interactions (though limited by Chainlit Action's `payload` type).
- When multiple tools are intercepted simultaneously, `action_requests` contains multiple items. This article simplifies by only taking the first; production should iterate through all.

## Summary

DeepAgents' `HumanInTheLoopMiddleware` encapsulates all the interrupt logic that previously required manual implementation. The key steps to integrate into a real application are:

1. **When creating the Agent**: Configure the `interrupt_on` dict + ensure a checkpointer is set
2. **Before each call**: Use `state.next` to determine if it's a normal conversation or interrupt resume
3. **When resuming**: Use `Command(resume={"decisions": [...]})` with the user's decision

The core logic is the same for both `ainvoke` and `astream` modes — only the interrupt detection differs (`.interrupts` attribute vs `__interrupt__` in the `updates` stream).
