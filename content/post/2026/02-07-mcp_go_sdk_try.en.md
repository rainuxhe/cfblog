+++
date = '2026-02-07T15:05:31+08:00'
draft = false
title = 'Exploring the Official MCP Go SDK'
description = 'Hands-on experience with the official MCP Go SDK: Building an MCP Server and an MCP Client that enables LLMs to autonomously select tools'
categories = ["program", "ai"]
tags = ["mcp", "golang", "ai"]
keywords = [
    "mcp",
    "golang",
	"ai",
]
slug = "exploring-the-official-mcp-go-sdk"
+++

## Introduction

I previously noticed on the MCP official website that an official Go SDK was available. Recently, after developing MCP Servers in Python environments for a while, I decided to try something different and explore Go.

From my personal experience, Go demonstrates significant advantages in concurrent processing: there's no need to worry about complex concurrency issues like synchronous blocking, asynchronous event loops, or inter-process/thread communication—goroutines handle it all elegantly. Additionally, Go offers convenient deployment; the compiled static binary files have excellent portability and can run directly across different environments.

However, this convenience comes with certain trade-offs. Compared to Python, implementing MCP functionality in Go is relatively more complex, with slightly lower development efficiency. This represents a classic software engineering trade-off: runtime costs and development costs are often difficult to optimize simultaneously, requiring careful consideration based on specific scenarios.

## Brief Introduction to MCP Protocol

*You might already be familiar with this, but for those who aren't, here's a quick overview of MCP.*

Model Context Protocol (MCP) is a standardized protocol designed to provide AI models with unified tool invocation interfaces. Through MCP, developers can expose various tools, services, and data sources to AI models, enabling them to perform operations beyond the capabilities of basic language models. MCP supports multiple transport protocols, including HTTP and Stdio, offering flexibility for integration in different scenarios.

## A Simple MCP Server Example

The official MCP Go SDK requires explicit definition of input parameters and output result data structures when defining tools (Tool). For simpler tools, the `any` type can also be used directly. Below is a complete MCP Server example providing three practical tools:

1. **`getCurrentDatetime`**: Retrieves the current time, returning a timestamp string in RFC3339 format (`2006-01-02T15:04:05Z07:00`). Since no input parameters are required, the parameter type is defined as `any`, with the output also using the `any` type.

2. **`getComputerStatus`**: Retrieves key system information including CPU usage, memory utilization, and system version. This tool accepts a `CPUSampleTime` parameter, with the corresponding input struct being `GetComputerStatusIn` and the output struct being `GetComputerStatusOut` (the Go SDK examples typically follow the naming convention of `xxxIn` and `xxxOut` to distinguish between tool input and output structs).

3. **`getDiskInfo`**: Retrieves usage information and filesystem details for all disk partitions. This tool requires no input parameters and only defines an output struct `GetDiskInfoOut`.

After implementing all tool logic, the final step is to start the service. The following example uses Streamable HTTP mode, with commented-out Stdio Transport mode code preserved for reference.

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
		Instructions: "Date and time related Server",
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

After successfully compiling the MCP Server code, it can be tested and verified in MCP-compatible development tools (such as VS Code). Below is a typical `.vscode/mcp.json` configuration example:

```json {linenos=true}
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

After starting the MCP Server, you can verify whether the tools are correctly scheduled and executed by asking relevant questions to the LLM.

## A Complete MCP Client Implementation

To build an end-to-end MCP application, we also need to implement an MCP Client that can work collaboratively with the LLM to automatically select and invoke appropriate tools. Below is a fully functional MCP Client implementation, including an integration example with OpenAI-compatible APIs (`callOpenAI` function).

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

// callOpenAI invokes the OpenAI API to handle user questions
// This function supports both streaming and non-streaming response modes
//
// Parameters:
//   - ctx: Context controlling the operation lifecycle
//   - question: User's question as a string
//   - stream: Boolean specifying whether to use streaming response
func callOpenAI(ctx context.Context, question string, stream bool) {
	client := openai.NewClient(option.WithAPIKey(FLAG_APIKEY), option.WithBaseURL(FLAG_BaseURL))
	systemPrompt := "Please answer the user's questions in a friendly and enthusiastic manner"

	if stream {
		// Create streaming response request
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
		// Iterate through streaming response and output content chunk by chunk
		for streamResp.Next() {
			data := streamResp.Current()
			fmt.Print(data.Choices[0].Delta.Content)

			if err := streamResp.Err(); err != nil {
				log.Fatalln(err)
			}
		}

	} else {
		// Create non-streaming response request
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
		// Output non-streaming response content
		fmt.Println(chatCompletion.Choices[0].Message.Content)
	}
}

// callOpenAIWithTools processes user questions using OpenAI API with MCP tool calls
// This function creates both an OpenAI client and an MCP client, converts MCP tools
// to OpenAI-compatible format, and executes the complete tool calling workflow,
// including initial calls and potential follow-up calls
//
// Parameters:
//   - ctx: Context controlling the operation lifecycle
//   - question: User's question as a string
func callOpenAIWithTools(ctx context.Context, question string) {
	// Create OpenAI client configured with API key and base URL
	llmClient := openai.NewClient(option.WithAPIKey(FLAG_APIKEY), option.WithBaseURL(FLAG_BaseURL))
	// Create MCP client with specified name and version
	mcpClient := mcp.NewClient(&mcp.Implementation{Name: "mcp-client", Version: "0.0.1"}, nil)
	var transport mcp.Transport
	// Select transport protocol based on command-line flag (stdio or http)
	switch FLAG_MCP_TRANSPORT {
	case "stdio":
		transport = &mcp.CommandTransport{Command: exec.Command(FLAG_MCP_URI)}
	case "http":
		transport = &mcp.StreamableClientTransport{HTTPClient: &http.Client{Timeout: time.Second * 10}, Endpoint: FLAG_MCP_URI}
	default:
		log.Fatalf("unknown transport, %s", FLAG_MCP_TRANSPORT)
	}
	// Establish connection with MCP server
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

	// Get available MCP tool list
	mcpTools, err := session.ListTools(ctx, &mcp.ListToolsParams{})
	if err != nil {
		log.Fatalf("List mcp tools failed, err: %v", err)
	}

	var legacyTools []openai.ChatCompletionToolUnionParam
	// Iterate through all MCP tools and convert them to OpenAI-compatible tool format
	for _, tool := range mcpTools.Tools {
		// Convert MCP tool input schema to OpenAI function parameters
		if inputSchema, ok := tool.InputSchema.(map[string]any); ok {
			legacyTools = append(legacyTools, openai.ChatCompletionFunctionTool(
				openai.FunctionDefinitionParam{
					Name:        tool.Name,
					Description: openai.String(tool.Description),
					Parameters:  openai.FunctionParameters(inputSchema),
				},
			))
		} else {
			// If InputSchema is not map[string]any, use empty parameters
			legacyTools = append(legacyTools, openai.ChatCompletionFunctionTool(
				openai.FunctionDefinitionParam{
					Name:        tool.Name,
					Description: openai.String(tool.Description),
					Parameters:  openai.FunctionParameters{},
				},
			))
		}
	}

	// Set initial chat messages including system prompt and user question
	messages := []openai.ChatCompletionMessageParamUnion{
		openai.SystemMessage("Please answer the user's questions in a friendly and enthusiastic manner. You can use available tools to gather information."),
		openai.UserMessage(question),
	}

	// Call LLM to get initial response
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

	// Check if tool calls are needed
	if choice.FinishReason == "tool_calls" && len(choice.Message.ToolCalls) > 0 {
		// Iterate through all required tool calls
		for _, toolCall := range choice.Message.ToolCalls {
			if toolCall.Type != "function" {
				continue
			}

			fmt.Printf("Executing tool: %s with args: %s\n", toolCall.Function.Name, toolCall.Function.Arguments)

			// Parse JSON arguments
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

			// Execute MCP tool call
			result, err := session.CallTool(ctx, &mcp.CallToolParams{
				Name:      toolCall.Function.Name,
				Arguments: argsObj,
			})
			if err != nil {
				log.Printf("Tool call failed: %v", err)
				continue
			}

			// Convert MCP content to string
			var toolResult string
			if len(result.Content) > 0 {
				if textContent, ok := result.Content[0].(*mcp.TextContent); ok {
					toolResult = textContent.Text
				} else {
					// If not TextContent, convert to JSON
					if jsonBytes, err := json.Marshal(result.Content[0]); err == nil {
						toolResult = string(jsonBytes)
					} else {
						toolResult = "Tool executed successfully"
					}
				}
			}

			fmt.Printf("Tool result: %s\n", toolResult)

			// Add tool call message and tool response message
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

			// Make follow-up call to get final response
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

### Running Tests for Verification

After compilation, we can perform multiple rounds of testing to verify functionality correctness.

**Basic Q&A Testing**:
```bash
./mcp-client-dev -api-key "sk-xxx" -q "how are you"
```

Stream output can also be enabled with the `-s` parameter:
```bash
./mcp-client-dev -api-key "sk-xxx" -q "how are you" -s
```

Expected output:
```
Hi there! 😊 I'm absolutely wonderful—energized, curious, and *so* happy to be chatting with you! 🌟 How about you? I'd love to hear how your day's going—or what's on your heart or mind right now! 💫 (Bonus points if you share a fun fact, a tiny win, or even just your favorite emoji today! 🍦✨)
```

**MCP Tool Call Testing**:
```bash
./mcp-client-dev -api-key "sk-xxx" -mcp-uri "http://127.0.0.1:18001/api/mcp" -q "What is the current time?"
```

Expected output:
```
LLM response: 
Executing tool: get_current_datetime with args: {}
Executing tool: get_current_datetime with parsed args: map[]
Tool result: "2026-02-02T23:12:54+08:00"
Final response: It's currently **February 2, 2026, at 11:12 PM** (Beijing Time, UTC+8) ✨
The festive atmosphere of the New Year is still warm~ Are you planning something special? 😊 I'd be delighted to help you organize, remind you, or brainstorm together!
```

## Best Practices and Considerations

When implementing an MCP Server in Go for production projects, consider the following best practices:

1. **Error Handling**: Ensure all tool functions have comprehensive error handling mechanisms to prevent service crashes due to individual tool failures.
2. **Performance Optimization**: For time-consuming operations (such as system information collection), consider adding timeout controls and caching mechanisms. (According to the official MCP documentation, there are new primitives called Tasks and progress—these could also be explored for time-consuming tasks.)
3. **Security**: Validate all input parameters to prevent security issues caused by malicious inputs. For tools involving system operations, pay special attention to permission controls.
4. **Logging**: Implement detailed logging to facilitate debugging and monitoring of tool usage.
5. **Configuration Management**: Extract service configurations (such as listening addresses and ports) into configuration files to improve maintainability.

## Conclusion

This article demonstrates how to develop MCP Servers and Clients using Go through a simple code example. Although Go is slightly more complex than Python for MCP development, its advantages in concurrent processing, performance, and deployment convenience make it an ideal choice for production environments.

It's important to note that this example only covers the basic functionality of MCP tool calls. When implementing an MCP Server in Go for actual business projects, further research into other MCP protocol features is necessary, such as Prompt management, authentication (Auth), session management, and other advanced functionalities.

Through thoughtful design and implementation, Go-based MCP services can provide AI applications with stable, efficient, and secure tool invocation capabilities, fully leveraging Go's strengths in system programming and network services.

## References

- MCP Official Website: [https://modelcontextprotocol.io/docs/getting-started/intro](https://modelcontextprotocol.io/docs/getting-started/intro)
- MCP Official Go SDK: [https://github.com/modelcontextprotocol/go-sdk](https://github.com/modelcontextprotocol/go-sdk)