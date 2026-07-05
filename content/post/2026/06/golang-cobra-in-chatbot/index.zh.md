+++
date = '2026-06-12T23:57:06+08:00'
draft = false
isCJKLanguage = true
title = 'Cobra 在聊天机器人中的应用'
description = '在聊天机器人服务中用cobra实现命令解析'
summary = '在聊天机器人服务中用cobra实现命令解析'
categories = ["program"]
tags = ["go", "cobra"]
keywords = ["golang", "cobra", "go", "chatbot"]
slug = 'golang-cobra-in-chatbot'
+++

## 前言

之前写过一篇用 Python argparse 在聊天机器人里解析命令的博客。最近把项目后端换成了 Go，命令解析这块用 Cobra 来替代 argparse，思路差不多，但实现上有一些 Go 特有的处理。

Cobra 是 Go 生态里最常用的 CLI 框架，kubectl、docker、hugo 这些工具都在用。不过 Cobra 默认是为命令行设计的——它会把输出直接写到 stdout/stderr，解析出错时还会调用 `os.Exit()`。在 HTTP 服务里用，得稍微改造一下。

## 流程逻辑

和 Python 版一样：

1. 用户通过 HTTP API `/api/chat` 发送消息
2. 后端按空格拆分消息文本，取第一段
3. 以 `/` 开头才走命令匹配，否则当自然语言处理
4. 匹配到命令后，去掉 `/` 前缀，把剩余参数交给 Cobra 解析执行
5. 返回结果给用户

同样不涉及 AI 自然语言处理部分，本文只讲命令解析。HTTP 框架只用标准库 `net/http`，不引入第三方 web 框架。

## 代码实现

代码结构很简单，三个文件：

```
├── cmd
│   ├── root.go      # 根命令 + Buffer 绑定
│   └── demo.go      # 示例子命令 /demo
├── main.go           # HTTP handler + 路由
├── go.mod
```

### 核心思路：把 Cobra 的输出抓进 Buffer

Cobra 执行命令时默认往 `os.Stdout` 和 `os.Stderr` 写。在 HTTP 服务里我们需要拿到这些输出内容，而不是让它们打印到控制台。

解决方式：创建一个 `bytes.Buffer`，通过 `SetOut()` 和 `SetErr()` 让 Cobra 写进去。请求处理完再从 Buffer 里读出来返回给客户端。

另外两个关键设置：

- `SilenceErrors = true` — 不让 Cobra 在出错时自动打印错误（因为错误也被 SetErr 重定向了，我们自己处理）
- `SilenceUsage = true` — 不让 Cobra 在出错时自动打印用法信息

```go
func NewRootCmd(buf *bytes.Buffer) *cobra.Command {
    rootCmd := &cobra.Command{
        Use:           "chatbot",
        SilenceErrors: true,
        SilenceUsage:  true,
    }
    rootCmd.SetOut(buf)
    rootCmd.SetErr(buf)
    rootCmd.AddCommand(NewDemoCmd())
    return rootCmd
}
```

### 每次请求新建 rootCmd

和 Python 版不同，Cobra 的 `Flags()` 方法返回的 flag set 是有状态的——如果你用同一个 rootCmd 实例处理多次请求，上一次请求的 flag 值可能会残留到下一次。

所以 **每个 HTTP 请求都 new 一个 rootCmd**，避免会话间变量污染。

### 子命令定义

以 `/demo` 为例，接受 `--name` 和 `--age` 两个参数。用 `Flags().StringVar()` 和 `Flags().IntVar()` 把 flag 值绑定到局部变量上，`RunE` 里直接读写就行。

```go
func NewDemoCmd() *cobra.Command {
    var name string
    var age int

    cmd := &cobra.Command{
        Use:   "demo",
        Short: "demo command",
        RunE: func(cmd *cobra.Command, args []string) error {
            _, err := fmt.Fprintf(
                cmd.OutOrStdout(),
                "hello %s, age=%d\n",
                name, age,
            )
            return err
        },
    }

    cmd.Flags().StringVar(&name, "name", "", "user name")
    cmd.Flags().IntVar(&age, "age", 0, "user age")

    return cmd
}
```

这里用 `cmd.OutOrStdout()` 而不是直接用 `fmt.Printf`，这样输出才会进 Buffer。

### HTTP Handler

`chatHandler` 的逻辑：

1. 只接受 POST
2. JSON 解码请求体，取出 `message` 字段
3. 空消息返回 error
4. 不以 `/` 开头 → 返回 "natural language message"（实际项目中交给 AI 模块）
5. 以 `/` 开头 → 用 `strings.Fields()` 拆分，去掉 `/` 前缀，交给 Cobra
6. Cobra 解析出错会返回 error，包装到 JSON 里返回给用户

```go
args := strings.Fields(req.Message)
args[0] = strings.TrimPrefix(args[0], "/")

buf := new(bytes.Buffer)
rootCmd := cmd.NewRootCmd(buf)
rootCmd.SetArgs(args)
err := rootCmd.Execute()
if err != nil {
    json.NewEncoder(w).Encode(ChatResponse{Error: err.Error()})
    return
}
json.NewEncoder(w).Encode(ChatResponse{Response: buf.String()})
```

## 实际效果

1. 发送 `/demo --name rainux --age 18`

```shell
curl --request POST \
  --url http://127.0.0.1:10001/api/chat \
  --header 'content-type: application/json' \
  --data '{
  "session_id": "qwerasd",
  "message": "/demo --name rainux --age 18"
}'

# 响应
{
  "response": "hello rainux, age=18\n"
}
```

2. 发送 `/demo --help` — Cobra 会自动生成帮助信息

```shell
curl --request POST \
  --url http://127.0.0.1:10001/api/chat \
  --header 'content-type: application/json' \
  --data '{
  "session_id": "qwerasd",
  "message": "/demo --help"
}'

# 响应
{
  "response": "Usage:\n  chatbot demo [flags]\n\nFlags:\n      --age int     user age\n  -h, --help         help for demo\n      --name string  user name\n"
}
```

3. 如果解析出错（比如 `--age` 传了非数字），Cobra 返回的 error 自然就进了 `ChatResponse.Error`：

```shell
curl --request POST \
  --url http://127.0.0.1:10001/api/chat \
  --header 'content-type: application/json' \
  --data '{
  "session_id": "qwerasd",
  "message": "/demo --name rainux --age abc"
}'

# 响应
{
  "error": "invalid argument \"abc\" for \"--age\" flag: strconv.ParseInt: parsing \"abc\": invalid syntax"
}
```

4. 自然语言消息不经过 Cobra：

```shell
curl --request POST \
  --url http://127.0.0.1:10001/api/chat \
  --header 'content-type: application/json' \
  --data '{
  "session_id": "qwerasd",
  "message": "今天天气怎么样"
}'

# 响应
{
  "response": "natural language message"
}
```

## 改进点

- 把 `strings.Fields()` 换成类似 `shlex` 的解析，让用户可以用引号包裹带空格的参数值
- 子命令注册目前是手动 `AddCommand`，可以考虑像 Python 版那样自动发现（不过在Go开发中，显式是优于隐式的）
- 权限控制、命令黑白名单之类的在实际项目里要考虑
- 错误信息提示的是 Go 原生的 strconv 错误，可以包装得更友好一些

## 完整示例代码

### `main.go`

```go
package main

import (
	"bytes"
	"cobra-http/cmd"
	"encoding/json"
	"log"
	"net/http"
	"strings"
)

type ChatRequest struct {
	Message   string `json:"message"`
	SessionID string `json:"session_id"`
}

type ChatResponse struct {
	Response string `json:"response,omitempty"`
	Error    string `json:"error,omitempty"`
}

func chatHandler(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Invalid request method", http.StatusMethodNotAllowed)
		return
	}

	var req ChatRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	req.Message = strings.TrimSpace(req.Message)

	if req.Message == "" {
		json.NewEncoder(w).Encode(ChatResponse{
			Error: "empty message",
		})
		return
	}

	if !strings.HasPrefix(req.Message, "/") {
		json.NewEncoder(w).Encode(ChatResponse{
			Response: "natural language message",
		})
		return
	}

	args := strings.Fields(req.Message)

	args[0] = strings.TrimPrefix(args[0], "/")

	buf := new(bytes.Buffer)
	rootCmd := cmd.NewRootCmd(buf)
	rootCmd.SetArgs(args)
	err := rootCmd.Execute()
	if err != nil {
		json.NewEncoder(w).Encode(ChatResponse{
			Error: err.Error(),
		})
		return
	}

	json.NewEncoder(w).Encode(ChatResponse{
		Response: buf.String(),
	})
}

func main() {

	http.HandleFunc("/api/chat", chatHandler)

	log.Println("server started at 127.0.0.1:10001")

	log.Fatal(http.ListenAndServe("127.0.0.1:10001", nil))
}
```

### `cmd/root.go`

```go
package cmd

import (
	"bytes"

	"github.com/spf13/cobra"
)

func NewRootCmd(buf *bytes.Buffer) *cobra.Command {
	rootCmd := &cobra.Command{
		Use:           "chatbot",
		SilenceErrors: true,
		SilenceUsage:  true,
	}

	// 把输出写入 buffer
	rootCmd.SetOut(buf)
	rootCmd.SetErr(buf)

	// 注册命令
	rootCmd.AddCommand(NewDemoCmd())

	return rootCmd
}
```

### `cmd/demo.go`

```go
package cmd

import (
	"fmt"

	"github.com/spf13/cobra"
)

func NewDemoCmd() *cobra.Command {
	var name string
	var age int

	cmd := &cobra.Command{
		Use:   "demo",
		Short: "demo command",
		RunE: func(cmd *cobra.Command, args []string) error {
			_, err := fmt.Fprintf(
				cmd.OutOrStdout(),
				"hello %s, age=%d\n",
				name,
				age,
			)

			return err
		},
	}

	cmd.Flags().StringVar(&name, "name", "", "user name")
	cmd.Flags().IntVar(&age, "age", 0, "user age")

	return cmd
}
```