+++
date = '2026-08-12T21:52:47+08:00'
lastmod = '2026-08-12T21:52:47+08:00'
draft = false
isCJKLanguage = true
title = '注册表工厂模式的简单实现'
description = '在 Golang 中，用注册表工厂模式实现一个简单的 job 调度器'
summary = '在 Golang 中，用注册表工厂模式实现一个简单的 job 调度器'
categories = ["program"]
tags = ["golang"]
keywords = ["golang"]
slug = 'register-factory-pattern-in-golang'
+++

## 前言

昨天在整合之前写的那些定时运行的小命令行工具，比如检测 DB 证书有效期、更新 Nginx SSL 证书、数据备份等。早期需求少，这些十几个小工具都是后期逐渐加上去的，一个工具就占一个文件夹，找起来还挺麻烦的，索性就整合成一个程序，根据命令行传参 job 名来运行指定 job。AI review 的时候说这是“基于 init 自注册的注册表工厂模式”，是个很常见的惯用写法。有点拗口，我缩减了一下就干脆叫“注册表工厂模式”。

> PS: 之前写 Python 的时候经常用 `__init_subclass__()` 实现继承即注册，再按类名调用对应的功能。Go 使用 `init()` 方法也能实现，算是异曲同工吧。 

## 模式介绍

这种模式最明显的特征就是在 `init()` 函数中将工厂方法注册到一个“注册表”中，从注册表中按名称或类型来调用工厂方法做实例化， 调用注册表方法的地方必定会有类似这样的 import： `_ "xxx"`。

最大的好处就是~~出问题 debug 的时候让同事找半天~~ **灵活**，新增功能只要在新代码中用 `init()` 注册，不需要手动维护注册表。核心逻辑不需要知道有哪些实现，第三方包通过被导入触发 `init()` 自注册来扩展能力。

比如标准库 `database/sql` 就是这么做的， `sql.Register` 注册驱动，`sql.Open("sqlite", dsn)` 按名字取。

## 示例代码

实际代码篇幅有点长，我就另外写了个简化版方便理解。

代码目录结构

```
├── go.mod
├── internal
│   ├── jobs  # 实际 job
│   │   ├── joba.go
│   │   └── jobb.go
│   └── register
│       └── register.go  # 注册表
├── main.go
├── Makefile
└── std-go-learn.bin  # 编译后的文件
```

### 注册表

注册表模块中声明 job 接口，以及注册表方法 `Register()` 和 `Create()`。`List()` 方法只是个辅助方法，让用户体验稍微好点，知道有哪些已注册的 job。

在定义注册表的模块中，不要导入有具体任务的模块，避免循环依赖。

```go
// internal/register/register.go
package register

import "fmt"

type Job interface {
	Name() string
	Run() error
}

// 存储已注册的 Job 类型
var factories = make(map[string]func() Job)

// Register 注册一个 Job 类型
func Register(name string, factory func() Job) {
	// 检查是否已注册, 防止同名注册
	if _, ok := factories[name]; ok {
		panic(fmt.Sprintf("job %s already registered", name))
	}
	factories[name] = factory
}

// Create 创建一个 Job 实例
func Create(name string) (Job, error) {
	if f, ok := factories[name]; ok {
		return f(), nil
	}
	return nil, fmt.Errorf("job not found: %s", name)
}

func List() string {
	availableJobs := ""
	for name := range factories {
		availableJobs += "- " + name + "\n"
	}
	return availableJobs
}
```

### 具体功能的结构体

作为示例，功能很简单，核心是实现接口和在 `init()` 中注册。

```go
// internal/jobs/joba.go
package jobs

import (
	"fmt"
	"std-go-learn/internal/register"
)

func init() {
	const jobName = "jobA"
	register.Register(jobName, func() register.Job {
		return &JobA{name: jobName}
	})
}

type JobA struct {
	name string
}

func (j *JobA) Name() string {
	return j.name
}

func (j *JobA) Run() error {
	fmt.Println("JobA is running")
	return nil
}


// internal/jobs/jobb.go
package jobs

import (
	"fmt"
	"std-go-learn/internal/register"
)

func init() {
	const jobName = "jobB"
	register.Register(jobName, func() register.Job {
		return &JobB{name: jobName}
	})
}

type JobB struct {
	name string
}

func (j *JobB) Name() string {
	return j.name
}

func (j *JobB) Run() error {
	fmt.Println("JobB is running")
	return nil
}
```

### 程序入口

在调用注册表的地方导入具体任务模块，做一些简单处理。

```go
package main

import (
	"flag"
	"fmt"
	"os"
	_ "std-go-learn/internal/jobs"
	"std-go-learn/internal/register"
)

func main() {
	// flag.StringVar(&flagJobName, "j", "", "job name")
	jobName := flag.String("j", "", "job name")
	flag.Parse()

	if *jobName == "" {
		fmt.Println("Must specify job name")
		flag.Usage()
		os.Exit(1)
	}

	job, err := register.Create(*jobName)
	if err != nil {
		fmt.Println("Failed to create job:", err)
		fmt.Printf("Available jobs:\n%s", register.List())
		os.Exit(1)
	}
	fmt.Println("Job name:", job.Name())
	if err := job.Run(); err != nil {
		fmt.Println("Failed to run job:", err)
		os.Exit(1)
	}
	fmt.Println("Job run successfully")
}
```

### 运行测试

正常调用 2 个已注册的 job

```shell
$ ./std-go-learn.bin -j jobA
Job name: jobA
JobA is running
Job run successfully

$ ./std-go-learn.bin -j jobB
Job name: jobB
JobB is running
Job run successfully
```

调用不存在的 job 会报错，并且退出码为非0，方便 shell 脚本判断。

```shell
$ ./std-go-learn.bin -j jobC
Failed to create job: job not found: jobC
Available jobs:
- jobA
- jobB
  
$ echo $?
1
```

## 补充

如果功能很少，也没后期扩展的需求，用 `if ... else` 或者 `switch ... case` 可能是更好的选择。这种隐式实现的程序，等到后期逻辑越来越复杂，代码篇幅越来越长，换一个不熟悉的人来维护，真有可能刚加一个功能但不知道要注册，找半天问题不知道为什么自己刚写的功能路由不到……😅