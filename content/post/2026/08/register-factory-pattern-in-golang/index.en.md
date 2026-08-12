+++
date = '2026-08-12T21:52:47+08:00'
lastmod = '2026-08-12T21:52:47+08:00'
draft = false
isCJKLanguage = false
title = 'A Simple Implementation of the Registry Factory Pattern'
description = 'Build a simple job scheduler in Go using the registry factory pattern'
summary = 'Build a simple job scheduler in Go using the registry factory pattern'
categories = ["program"]
tags = ["golang", "AI-Translated"]
keywords = ["golang"]
slug = 'register-factory-pattern-in-golang'
+++

## Introduction

Yesterday I was consolidating the small CLI tools I'd written over time to run on a schedule — checking DB certificate expiry, renewing Nginx SSL certificates, backing up data, and so on. In the early days I had few requirements, and those dozen or so little tools were added gradually, one folder per tool, which got tedious to navigate. So I decided to merge them into a single program that runs a given job by name passed in as a command-line argument. During AI review, this was described as a "registry factory pattern with init-based self-registration" — a very common idiom. That name was a mouthful, so I shortened it to just "registry factory pattern".

> PS: When I used to write Python, I often relied on `__init_subclass__()` to register on inheritance and then dispatch by class name. Go's `init()` achieves the same effect — different strokes, same result.

## The Pattern

The defining trait of this pattern is registering factory functions into a "registry" inside `init()`, and later instantiating by looking up the registry by name or type. Wherever the registry is consumed, you're guaranteed to see a blank import like this: `_ "xxx"`.

The biggest payoff is **flexibility** — add a feature by registering it in `init()`, with no registry to maintain by hand. The core logic doesn't need to know what implementations exist; third-party packages extend the system by being imported and self-registering.

The standard library's `database/sql` works exactly this way: drivers register via `sql.Register`, and `sql.Open("sqlite", dsn)` fetches them by name.

## Sample Code

The real code got a bit long, so I wrote a simplified version for clarity.

Directory layout

```
├── go.mod
├── internal
│   ├── jobs  # actual jobs
│   │   ├── joba.go
│   │   └── jobb.go
│   └── register
│       └── register.go  # the registry
├── main.go
├── Makefile
└── std-go-learn.bin  # compiled binary
```

### The Registry

The registry module declares the `Job` interface along with the `Register()` and `Create()` functions. `List()` is just a convenience so users can see which jobs are registered.

Don't import any modules with concrete tasks from the registry module, to avoid circular dependencies.

```go
// internal/register/register.go
package register

import "fmt"

type Job interface {
	Name() string
	Run() error
}

// factories stores the registered Job types
var factories = make(map[string]func() Job)

// Register registers a Job type
func Register(name string, factory func() Job) {
	// check for duplicates to prevent name collisions
	if _, ok := factories[name]; ok {
		panic(fmt.Sprintf("job %s already registered", name))
	}
	factories[name] = factory
}

// Create instantiates a Job by name
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

### The Concrete Jobs

As a demo, the functionality is trivial — the point is implementing the interface and registering in `init()`.

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

### The Entry Point

At the call site, import the concrete job modules and handle the details.

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

### Running It

Calling the two registered jobs normally

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

Requesting an unregistered job fails with a non-zero exit code, which makes it easy to check from a shell script.

```shell
$ ./std-go-learn.bin -j jobC
Failed to create job: job not found: jobC
Available jobs:
- jobA
- jobB
  
$ echo $?
1
```

## Closing Thoughts

If you have few jobs and no plans to extend, `if ... else` or `switch ... case` may serve you better. With implicit registration like this, as the logic grows more complex and the codebase gets longer, an unfamiliar maintainer might add a feature without knowing they need to register it — and then spend ages wondering why their brand-new code never gets routed. 😅
