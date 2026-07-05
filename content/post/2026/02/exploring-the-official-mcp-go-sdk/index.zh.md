+++
date = '2026-02-07T15:05:31+08:00'
draft = false
title = 'MCP官方Go SDK尝鲜'
description = 'MCP 官方 Go SDK尝鲜, 构建MCP Server和支持LLM自主抉择tool的MCP Client'
summary = '使用Go SDK构建MCP Server和Client'
categories = ["program", "ai"]
tags = ["mcp", "go", "ai"]
keywords = [
    "mcp",
    "golang",
    "ai",
]
slug = "exploring-the-official-mcp-go-sdk"
+++

## 前言

此前在 MCP 官网就注意到官方提供了 Go SDK，近期由于在 Python 环境下开发 MCP Server 有点"审美疲劳"，因此决定使用 Go 语言尝尝鲜。

从个人实际体验来看，Go 语言在并发处理方面确实具有显著优势：无需纠结于同步阻塞、异步事件循环、多进程多线程通信等复杂的并发问题，goroutine 一把梭哈。同时，Go 语言的部署也非常便捷，编译后生成的静态二进制文件具有良好的可移植性，可以在不同环境中直接运行。

然而，这种便利性也伴随着一定的代价。相较于 Python，使用 Go 语言实现 MCP 功能相对复杂一些，开发效率略低。这就是软件工程中的经典权衡了：运行成本与开发成本往往难以兼得，需要根据具体场景进行取舍。

## MCP 协议简介

*可能都耳熟能详了，但以防还有不熟悉的朋友，先简单介绍下MCP*

Model Context Protocol (MCP) 是一种标准化的协议，旨在为 AI 模型提供统一的工具调用接口。通过 MCP，开发者可以将各种工具、服务和数据源暴露给 AI 模型，使其能够执行超出基础语言模型能力范围的操作。MCP 支持多种传输协议，包括 HTTP 和 Stdio，为不同场景下的集成提供了灵活性。

## 一个简单的 MCP Server 示例

MCP 官方 Go SDK 在定义工具（Tool）时，要求明确指定输入参数和输出结果的数据结构。对于功能较为简单的工具，也可以直接使用 `any` 类型。以下是一个完整的 MCP Server 示例，提供了三个实用工具：

1. **`getCurrentDatetime`**：获取当前时间，返回 RFC3339 格式（`2006-01-02T15:04:05Z07:00`）的时间戳字符串。由于不需要输入参数，因此参数类型定义为 `any`，输出同样使用 `any` 类型。

2. **`getComputerStatus`**：获取当前系统的关键信息，包括 CPU 使用率、内存使用情况、系统版本等。该工具接受一个 `CPUSampleTime` 参数，对应的输入结构体为 `GetComputerStatusIn`，输出结构体为 `GetComputerStatusOut`（Go SDK 的示例中通常采用 `xxxIn` 和 `xxxOut` 的命名约定来区分工具的输入输出结构体）。

3. **`getDiskInfo`**：获取所有硬盘分区的使用信息和文件系统详情。该工具无需输入参数，仅定义了输出结构体 `GetDiskInfoOut`。

在完成所有工具逻辑的实现后，最后一步是启动服务。以下示例采用 Streamable HTTP 模式启动，同时也保留了 Stdio Transport 模式的注释代码供参考。

```go {linenos=true}
package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"net/http"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/host"
	"github.com/shirou/gopsutil/v4/mem"
)

func getCurrentDatetime(ctx context.Context, req *mcp.CallToolRequest, arg any) (*mcp.CallToolResult, any, error) {
	now := time.Now().Format(time.RFC3339)
	return nil, now, nil
}

type GetComputerStatusIn struct {
	CPUSampleTime time.Duration `json:"cpu_sample_time" jsonschema:"the sample time of cpu usage. Default is 1s"`
}

type GetComputerStatusOut struct {
	Hostinfo    string `json:"host info" jsonschema:"the hostinfo of the computer"`
	TimeZone    string `json:"time_zone" jsonschema:"the time zone of the computer"`
	IPAddress   string `json:"ip_address" jsonschema:"the ip address of the computer"`
	CPUUsage    string `json:"cpu_usage" jsonschema:"the cpu usage of the computer"`
	MemoryUsage string `json:"memory_usage" jsonschema:"the memory usage of the computer"`
}

func getComputerStatus(ctx context.Context, req *mcp.CallToolRequest, args GetComputerStatusIn) (*mcp.CallToolResult, GetComputerStatusOut, error) {
	if args.CPUSampleTime == 0 {
		args.CPUSampleTime = time.Second
	}
	hInfo, err := host.Info()
	if err != nil {
		return nil, GetComputerStatusOut{}, err
	}

	var resp GetComputerStatusOut
	resp.Hostinfo = fmt.Sprintf("%+v", *hInfo)

	name, offset := time.Now().Zone()
	resp.TimeZone = fmt.Sprintf("Timezone: %s (UTC%+d)\n", name, offset/3600)

	// CPU Usage
	percent, err := cpu.Percent(time.Second, false)
	if err != nil {
		return nil, GetComputerStatusOut{}, err
	}
	resp.CPUUsage = fmt.Sprintf("CPU Usage: %.2f%%\n", percent[0])

	// Memory Usage
	v, err := mem.VirtualMemory()
	if err != nil {
		return nil, GetComputerStatusOut{}, err
	}
	resp.MemoryUsage = fmt.Sprintf("Mem Usage: %.2f%% (Used: %vMB / Total: %vMB)\n",
		v.UsedPercent, v.Used/1024/1024, v.Total/1024/1024)

	// Ip Address
	conn, err := net.Dial("udp", "8.8.8.8:80")
	if err != nil {
		return nil, GetComputerStatusOut{}, err
	}
	defer conn.Close()
	localAddr := conn.LocalAddr().(*net.UDPAddr)
	resp.IPAddress = localAddr.IP.String()

	return nil, resp, nil
}

type DiskInfo struct {
	Device     string   `json:"device" jsonschema:"the device name"`
	Mountpoint string   `json:"mountpoint" jsonschema:"the mountpoint"`
	Fstype     string   `json:"fstype" jsonschema:"the filesystem type"`
	Opts       []string `json:"opts" jsonschema:"the mount options"`
	DiskTotal  uint64   `json:"disk_total" jsonschema:"the total disk space in GiB"`
	DiskUsage  float64  `json:"disk_usage" jsonschema:"the disk usage percentage"`
}

type GetDiskInfoOut struct {
	PartInfos []DiskInfo `json:"part_infos" jsonschema:"the disk partitions"`
}

func getDiskInfo(ctx context.Context, req *mcp.CallToolRequest, args any) (*mcp.CallToolResult, GetDiskInfoOut, error) {
	partInfos, err := disk.Partitions(false)
	if err != nil {
		return nil, GetDiskInfoOut{}, err
	}

	var resp []DiskInfo
	for _, part := range partInfos {
		diskUsage, err := disk.Usage(part.Mountpoint)
		if err != nil {
			continue
		}
		resp = append(resp, DiskInfo{
			Device:     part.Device,
			Mountpoint: part.Mountpoint,
			Fstype:     part.Fstype,
			Opts:       part.Opts,
			DiskTotal:  diskUsage.Total / 1024 / 1024 / 1024,
			DiskUsage:  diskUsage.UsedPercent,
		})
	}
	return nil, GetDiskInfoOut{PartInfos: resp}, nil
}

func main() {
	// ctx := context.Background()

	server := mcp.NewServer(&mcp.Implementation{Name: "MCP_Demo", Version: "0.0.1"}, &mcp.ServerOptions{
		Instructions: "日期时间相关的 Server",
	})
	mcp.AddTool(server, &mcp.Tool{
		Name:        "get_current_datetime",
		Description: "Get current datetime in RFC3339 format",
	}, getCurrentDatetime)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "get_computer_status",
		Description: "Get computer status",
	}, getComputerStatus)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "get_disk_info",
		Description: "Get disk information",
	}, getDiskInfo)

	// if err := server.Run(ctx, &mcp.StdioTransport{}); err != nil {
	// 	log.Fatalln(err)
	// }
	//
	handler := mcp.NewStreamableHTTPHandler(func(req *http.Request) *mcp.Server {
		path := req.URL.Path
		switch path {
		case "/api/mcp":
			return server
		default:
			return nil
		}
	}, nil)
	url := "127.0.0.1:18001"
	if err := http.ListenAndServe(url, handler); err != nil {
		log.Fatalln(err)
	}
}
```

MCP Server 代码编译通过后，可以在支持 MCP 协议的开发工具（如 VS Code）中进行测试验证。以下是一个典型的 `.vscode/mcp.json` 配置示例：

```json
{
    "servers": {
        "demo-http": {
            // "command": "/home/rainux/Documents/workspace/go-dev/mcp-dev/mcp-server-dev/mcp-server-dev"
            "type": "http",
            "url": "http://127.0.0.1:18001/api/mcp"
        }
    }
}
```

启动 MCP Server 后，可以通过向 LLM 提出相关问题来验证工具是否能够被正确调度和执行。

## 一个完整的 MCP Client 实现

为了构建端到端的 MCP 应用，我们还需要实现一个 MCP Client，使其能够与 LLM 协同工作，自动选择并调用合适的工具。以下是一个功能完整的 MCP Client 实现，其中包含了与 OpenAI 兼容 API 的集成示例（`callOpenAI` 函数）。

```go {linenos=true}
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os/exec"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/openai/openai-go/v3"
	"github.com/openai/openai-go/v3/option"
	"github.com/openai/openai-go/v3/packages/param"
)

var (
	FLAG_ModelName     string
	FLAG_BaseURL       string
	FLAG_APIKEY        string
	FLAG_MCP_TRANSPORT string
	FLAG_MCP_URI       string
	FLAG_QUESTION      string
	FLAG_STREAM        bool
)

func main() {
	// Parse command-line flags
	flag.StringVar(&FLAG_BaseURL, "base-url", "https://dashscope.aliyuncs.com/compatible-mode/v1", "llm base url")
	flag.StringVar(&FLAG_ModelName, "model", "qwen-plus", "LLM Model Name")
	flag.StringVar(&FLAG_MCP_TRANSPORT, "mcp-transport", "http", "MCP transport protocol (stdio or http)")
	flag.StringVar(&FLAG_MCP_URI, "mcp-uri", "", "MCP server address")
	flag.StringVar(&FLAG_APIKEY, "api-key", "", "llm api key")
	flag.StringVar(&FLAG_QUESTION, "q", "Hi", "question")
	flag.BoolVar(&FLAG_STREAM, "s", false, "stream response")

	flag.Parse()

	// Get configuration from environment variables with flag overrides
	if FLAG_APIKEY == "" {
		log.Fatalln("api key is empty")
	}

	if FLAG_QUESTION == "" {
		log.Fatalln("question is empty")
	}

	// Configure OpenAI client
	// config :=
	ctx := context.Background()

	// question := "Write me a haiku about computers"
	if FLAG_MCP_URI != "" {
		callOpenAIWithTools(ctx, FLAG_QUESTION)
	} else {
		callOpenAI(ctx, FLAG_QUESTION, FLAG_STREAM)
	}
}

// callOpenAI 调用 OpenAI API 接口处理用户问题
// 该函数支持流式（stream）和非流式（non-stream）两种响应方式
//
// 参数:
//   - ctx: 控制操作生命周期的上下文
//   - question: 用户提出的问题字符串
//   - stream: 布尔值，指定是否使用流式响应
func callOpenAI(ctx context.Context, question string, stream bool) {
	client := openai.NewClient(option.WithAPIKey(FLAG_APIKEY), option.WithBaseURL(FLAG_BaseURL))
	systemPrompt := "请用亲切热情的风格回答用户的问题"

	if stream {
		// 创建流式响应请求
		streamResp := client.Chat.Completions.NewStreaming(ctx, openai.ChatCompletionNewParams{
			Messages: []openai.ChatCompletionMessageParamUnion{
				openai.SystemMessage(systemPrompt),
				openai.UserMessage(question),
			},
			Model: FLAG_ModelName,
		})
		// defer streamResp.Close()
		defer func() {
			err := streamResp.Close()
			if err != nil {
				log.Fatalln(err)
			}
		}()
		// 遍历流式响应并逐块输出内容
		for streamResp.Next() {
			data := streamResp.Current()
			fmt.Print(data.Choices[0].Delta.Content)

			if err := streamResp.Err(); err != nil {
				log.Fatalln(err)
			}
		}

	} else {
		// 创建非流式响应请求
		chatCompletion, err := client.Chat.Completions.New(ctx, openai.ChatCompletionNewParams{
			Messages: []openai.ChatCompletionMessageParamUnion{
				openai.SystemMessage(systemPrompt),
				openai.UserMessage(question),
			},
			Model: FLAG_ModelName,
		})
		if err != nil {
			log.Fatalln(err)
		}
		// 输出非流式响应内容
		fmt.Println(chatCompletion.Choices[0].Message.Content)
	}
}

// callOpenAIWithTools 使用 OpenAI API 和 MCP 工具调用来处理用户问题
// 该函数创建一个 OpenAI 客户端和 MCP 客户端，将 MCP 工具转换为 OpenAI 可使用的格式，
// 并执行完整的工具调用流程，包括初始调用和可能的后续调用
//
// 参数:
//   - ctx: 控制操作生命周期的上下文
//   - question: 用户提出的问题字符串
func callOpenAIWithTools(ctx context.Context, question string) {
	// 创建 OpenAI 客户端，使用 API 密钥和基础 URL 配置
	llmClient := openai.NewClient(option.WithAPIKey(FLAG_APIKEY), option.WithBaseURL(FLAG_BaseURL))
	// 创建 MCP 客户端，指定名称和版本
	mcpClient := mcp.NewClient(&mcp.Implementation{Name: "mcp-client", Version: "0.0.1"}, nil)
	var transport mcp.Transport
	// 根据命令行标志选择传输协议（stdio 或 http）
	switch FLAG_MCP_TRANSPORT {
	case "stdio":
		transport = &mcp.CommandTransport{Command: exec.Command(FLAG_MCP_URI)}
	case "http":
		transport = &mcp.StreamableClientTransport{HTTPClient: &http.Client{Timeout: time.Second * 10}, Endpoint: FLAG_MCP_URI}
	default:
		log.Fatalf("unknown transport, %s", FLAG_MCP_TRANSPORT)
	}
	// 建立与 MCP 服务器的连接
	session, err := mcpClient.Connect(ctx, transport, nil)
	if err != nil {
		log.Fatalf("MCP client connects to mcp server failed, err: %v", err)
	}
	defer func() {
		err := session.Close()
		if err != nil {
			log.Fatalln(err)
		}
	}()

	// 获取可用的 MCP 工具列表
	mcpTools, err := session.ListTools(ctx, &mcp.ListToolsParams{})
	if err != nil {
		log.Fatalf("List mcp tools failed, err: %v", err)
	}

	var legacyTools []openai.ChatCompletionToolUnionParam
	// 遍历所有 MCP 工具并将其转换为 OpenAI 兼容的工具格式
	for _, tool := range mcpTools.Tools {
		// 将 MCP 工具输入模式转换为 OpenAI 函数参数
		if inputSchema, ok := tool.InputSchema.(map[string]any); ok {
			legacyTools = append(legacyTools, openai.ChatCompletionFunctionTool(
				openai.FunctionDefinitionParam{
					Name:        tool.Name,
					Description: openai.String(tool.Description),
					Parameters:  openai.FunctionParameters(inputSchema),
				},
			))
		} else {
			// 如果 InputSchema 不是 map[string]any，使用空参数
			legacyTools = append(legacyTools, openai.ChatCompletionFunctionTool(
				openai.FunctionDefinitionParam{
					Name:        tool.Name,
					Description: openai.String(tool.Description),
					Parameters:  openai.FunctionParameters{},
				},
			))
		}
	}

	// 设置初始聊天消息，包括系统提示和用户问题
	messages := []openai.ChatCompletionMessageParamUnion{
		openai.SystemMessage("请用亲切热情的风格回答用户的问题。你可以使用可用的工具来获取信息。"),
		openai.UserMessage(question),
	}

	// 调用 LLM 获取初步响应
	chatCompletion, err := llmClient.Chat.Completions.New(ctx, openai.ChatCompletionNewParams{
		Messages: messages,
		Model:    FLAG_ModelName,
		Tools:    legacyTools,
		ToolChoice: openai.ChatCompletionToolChoiceOptionUnionParam{
			OfAuto: param.Opt[string]{
				Value: "auto",
			},
		},
	})
	if err != nil {
		log.Fatalf("LLM call failed, err: %v", err)
	}

	choice := chatCompletion.Choices[0]
	fmt.Printf("LLM response: %s\n", choice.Message.Content)

	// 检查是否需要调用工具
	if choice.FinishReason == "tool_calls" && len(choice.Message.ToolCalls) > 0 {
		// 遍历所有需要调用的工具
		for _, toolCall := range choice.Message.ToolCalls {
			if toolCall.Type != "function" {
				continue
			}

			fmt.Printf("Executing tool: %s with args: %s\n", toolCall.Function.Name, toolCall.Function.Arguments)

			// 解析 JSON 参数
			var argsObj map[string]any
			args := toolCall.Function.Arguments

			if args != "" {
				if err := json.Unmarshal([]byte(args), &argsObj); err != nil {
					log.Printf("Failed to parse tool arguments: %v", err)
					argsObj = make(map[string]any)
				}
			} else {
				argsObj = make(map[string]any)
			}

			fmt.Printf("Executing tool: %s with parsed args: %v\n", toolCall.Function.Name, argsObj)

			// 执行 MCP 工具调用
			result, err := session.CallTool(ctx, &mcp.CallToolParams{
				Name:      toolCall.Function.Name,
				Arguments: argsObj,
			})
			if err != nil {
				log.Printf("Tool call failed: %v", err)
				continue
			}

			// 将 MCP 内容转换为字符串
			var toolResult string
			if len(result.Content) > 0 {
				if textContent, ok := result.Content[0].(*mcp.TextContent); ok {
					toolResult = textContent.Text
				} else {
					// 如果不是 TextContent，转换为 JSON
					if jsonBytes, err := json.Marshal(result.Content[0]); err == nil {
						toolResult = string(jsonBytes)
					} else {
						toolResult = "Tool executed successfully"
					}
				}
			}

			fmt.Printf("Tool result: %s\n", toolResult)

			// 添加工具调用消息和工具响应消息
			messages = append(messages, openai.ChatCompletionMessageParamUnion{
				OfAssistant: &openai.ChatCompletionAssistantMessageParam{
					Role: "assistant",
					ToolCalls: []openai.ChatCompletionMessageToolCallUnionParam{
						{
							OfFunction: &openai.ChatCompletionMessageFunctionToolCallParam{
								ID: toolCall.ID,
								Function: openai.ChatCompletionMessageFunctionToolCallFunctionParam{
									Name:      toolCall.Function.Name,
									Arguments: toolCall.Function.Arguments,
								},
							},
						},
					},
				},
			})

			messages = append(messages, openai.ToolMessage(
				toolResult,
				toolCall.ID,
			))

			// 进行后续调用以获得最终响应
			chatCompletion, err = llmClient.Chat.Completions.New(ctx, openai.ChatCompletionNewParams{
				Messages: messages,
				Model:    FLAG_ModelName,
			})
			if err != nil {
				log.Fatalf("LLM follow-up failed, err: %v", err)
			}

			fmt.Printf("Final response: %s\n", chatCompletion.Choices[0].Message.Content)
		}
	}
}
```

### 运行测试验证

编译完成后，我们可以进行多轮测试来验证功能的正确性。

**普通问答测试**：
```bash
./mcp-client-dev -api-key "sk-xxx" -q "how are you"
```

还可以加上 `-s` 参数启用流式输出：
```bash
./mcp-client-dev -api-key "sk-xxx" -q "how are you" -s
```

预期输出：
```
Hi there! 😊 I'm absolutely wonderful—energized, curious, and *so* happy to be chatting with you! 🌟 How about you? I'd love to hear how your day's going—or what's on your heart or mind right now! 💫 (Bonus points if you share a fun fact, a tiny win, or even just your favorite emoji today! 🍦✨)
```

**MCP 工具调用测试**：
```bash
./mcp-client-dev -api-key "sk-xxx" -mcp-uri "http://127.0.0.1:18001/api/mcp" -q "当前时间是什么"
```

预期输出：
```
LLM response: 
Executing tool: get_current_datetime with args: {}
Executing tool: get_current_datetime with parsed args: map[]
Tool result: "2026-02-02T23:12:54+08:00"
Final response: 现在是 **2026 年 2 月 2 日 晚上 11:12**（北京时间，UTC+8）✨
新年的气息还暖暖的～你是在规划什么特别的事情吗？😊 我很乐意帮你安排、提醒或一起畅想哦！
```

## 最佳实践与注意事项

在实际项目中使用 Go 语言实现 MCP Server 时，建议考虑以下最佳实践：

1. **错误处理**：确保所有工具函数都有完善的错误处理机制，避免因单个工具失败导致整个服务崩溃。
2. **性能优化**：对于耗时较长的操作（如系统信息采集），考虑添加超时控制和缓存机制。(在MCP官方文档看到有 Tasks 和 progress 这两个新的原语, 耗时任务也可以试试这两个)
3. **安全性**：验证所有输入参数，防止恶意输入导致的安全问题。对于涉及系统操作的工具，需要特别注意权限控制。
4. **日志记录**：添加详细的日志记录，便于调试和监控工具的使用情况。
5. **配置管理**：将服务配置（如监听地址、端口等）提取到配置文件中，提高可维护性。

## 总结

本文通过一个简单的代码示例展示了如何使用 Go 语言开发 MCP Server 和 Client。虽然 Go 语言在 MCP 开发方面相比 Python 略显复杂，但其在并发处理、性能和部署便利性方面的优势使其成为生产环境的理想选择。

需要注意的是，本文示例仅涵盖了 MCP 工具调用的基本功能。在实际业务项目中使用 Go 语言实现 MCP Server 时，还需要深入研究 MCP 协议的其他特性，如 Prompt 管理、身份认证（Auth）、会话管理等高级功能的实现方案。

通过合理的设计和实现，基于 Go 语言的 MCP 服务可以为 AI 应用提供稳定、高效、安全的工具调用能力，充分发挥 Go 语言在系统编程和网络服务方面的优势。

## 参考

- MCP 官方页面: [https://modelcontextprotocol.io/docs/getting-started/intro](https://modelcontextprotocol.io/docs/getting-started/intro)
- MCP 官方 Go SDK: [https://github.com/modelcontextprotocol/go-sdk](https://github.com/modelcontextprotocol/go-sdk)