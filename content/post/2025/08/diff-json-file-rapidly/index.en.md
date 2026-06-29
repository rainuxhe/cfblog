+++
date = '2025-08-10T00:21:20+08:00'
draft = false
title = 'Go/Python - Rapidly Diff Two JSON Files'
description = 'Diff Json File Rapidly'
summary = 'Rapidly diff large JSON files with Python and Go'
categories = ["program"]
tags = ["go", "python", "AI-Translated"]
keywords = ["go", "python", "json"]
slug = 'diff-json-file-rapidly'
+++

## Preface

A while ago, a colleague needed to compare differences between two JSON files. Being a database expert, they implemented this using SQL — a feat that left me, someone who only knows CRUD, in awe. We tested it on a JSON file with over 10 million characters and more than 400,000 lines, and the SQL query took 9 seconds. I had some free time on Saturday, so I studied my colleague's SQL and decided to try implementing it in Python and Go.

The test JSON files are as follows. `dst.json` was copied from `src.json` with a random modification somewhere. Each file has approximately 409,510 lines and about 11,473,154 characters.

```bash
$ wc -ml ./src.json dst.json
409510 11473154 ./src.json
409510 11473155 dst.json
819020 22946309 total
```

## Third-Party Library: jsondiff

First, I searched online for existing third-party libraries and found one called `jsondiff`. After installing it with `pip`:

```python
import json
import jsondiff
import os
from typing import Any

def read_json(filepath: str) -> Any:
    if not os.path.exists(filepath):
        raise FileNotFoundError(filepath)
    try:
        with open(filepath, "r") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        raise Exception(f"{filepath} is not a valid json file") from e
    else:
        return data
    
if __name__ == "__main__":
    src_data = read_json("src.json")
    dst_data = read_json("dst.json")

    diffs = jsondiff.diff(src_data, dst_data)
    print(diffs)
```

Test run:

```bash
$ /usr/bin/time -f 'Elapsed Time: %e s Max RSS: %M kbytes' python third.py
{'timepicker': {'time_options': {insert: [(7, '7dd')], delete: [7]}}}
Elapsed Time: 1576.30 s Max RSS: 87732 kbytes
```

The runtime was way too long — nearly half an hour. Definitely not usable.

## Python - Using Only the Standard Library

After trying just the one third-party library, I decided to follow my colleague's SQL approach and implement it using only the standard library.

```python
from typing import Any, List
import json
import os
from dataclasses import dataclass
from collections.abc import MutableSequence, MutableMapping

@dataclass
class DiffResult:
    path: str
    kind: str
    left: Any
    right: Any

def add_path(parent: str, key: str) -> str:
    """Combine parent path and key name into a complete path string"""
    if parent == "":
        return key
    else:
        return parent + "." + key
    
def read_json(filepath: str) -> Any:
    if not os.path.exists(filepath):
        raise FileNotFoundError(filepath)
    try:
        with open(filepath, "r") as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        raise Exception(f"{filepath} is not a valid json file") from e
    else:
        return data
    
def collect_diff(path: str, left: Any, right: Any) -> List[DiffResult]:
    """Compare differences between two JSON data structures
    
    Args:
        path (str): Current path
        left (Any): Left-side data
        right (Any): Right-side data

    Returns:
        List[DiffResult]: List of differences
    """
    diffs: List[DiffResult] = []

    if isinstance(left, MutableMapping) and isinstance(right, MutableMapping):
        # Handle dict: check key additions, deletions, and modifications
        all_keys = set(left.keys()) | set(right.keys())
        for k in all_keys:
            l_exists = k in left
            r_exists = k in right
            key_path = add_path(path, k)

            if l_exists and not r_exists:
                diffs.append(DiffResult(key_path, "removed", left=left[k]))
            elif not l_exists and r_exists:
                diffs.append(DiffResult(key_path, "added", right=right[k]))
            else:
                diffs.extend(collect_diff(key_path, left[k], right[k]))

    elif isinstance(left, MutableSequence) and isinstance(right, MutableSequence):
        max_len = max(len(left), len(right))
        for i in range(max_len):
            l_exists = i < len(left)
            r_exists = i < len(right)
            idx_path = f"{path}[{i}]"

            lv = left[i] if l_exists else None
            rv = right[i] if r_exists else None 

            if l_exists and not r_exists:
                diffs.append(DiffResult(idx_path, "removed", left=lv))
            elif not l_exists and r_exists:
                diffs.append(DiffResult(idx_path, "added", right=rv))
            else:
                diffs.extend(collect_diff(idx_path, lv, rv))

    else:
        if left != right:
            diffs.append(DiffResult(path, "modified", left=left, right=right))

    return diffs

if __name__ == "__main__":
    src_dict = read_json("src.json")
    dst_dict = read_json("dst.json")

    diffs = collect_diff("", src_dict, dst_dict)
    if len(diffs) == 0:
        print("No differences found.")
    else:
        print(f"Found {len(diffs)} differences:")
        for diff in diffs:
            match diff.kind:
                case "added":
                    print(f"Added: {diff.path}, {diff.right}")
                case "removed":
                    print(f"Removed: {diff.path}, {diff.left}")
                case "modified":
                    print(f"Modified: {diff.path}, {diff.left} -> {diff.right}")
```

Test run:

```bash
$ /usr/bin/time -f 'Elapsed Time: %e s Max RSS: %M kbytes' python main.py
Found 1 differences:
Modified: timepicker.time_options[7], 7d -> 7dd
Elapsed Time: 0.46 s Max RSS: 87976 kbytes
```

Just 0.46 seconds to find the differences. In terms of pure comparison performance, this is far better than `jsondiff`.

## Go Implementation

Let's also implement a command-line tool in Go, again using only the standard library.

```go
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
)

var (
	src_file string
	dst_file string
)

type DiffResult struct {
	Path  string
	Kind  string
	Left  any
	Right any
}

func addPath(parent, key string) string {
	if parent == "" {
		return key
	}
	return parent + "." + key
}

func collectDiff(path string, left, right any) []DiffResult {
	var diffs []DiffResult

	switch l := left.(type) {
	case map[string]any:
		if r, ok := right.(map[string]any); ok {
			for k, lv := range l {
				rk, exists := r[k]
				if !exists {
					diffs = append(diffs, DiffResult{
						Path:  addPath(path, k),
						Kind:  "removed",
						Left:  lv,
						Right: nil,
					})
				} else {
					diffs = append(diffs, collectDiff(addPath(path, k), lv, rk)...)
				}
			}

			for k, rv := range r {
				if _, exists := l[k]; !exists {
					diffs = append(diffs, DiffResult{
						Path:  addPath(path, k),
						Kind:  "added",
						Left:  nil,
						Right: rv,
					})
				}
			}
		} else {
			diffs = append(diffs, DiffResult{
				Path:  path,
				Kind:  "modified",
				Left:  left,
				Right: right,
			})
		}
	case []any:
		if r, ok := right.([]any); ok {
			maxLen := len(l)
			if len(r) > maxLen {
				maxLen = len(r)
			}
			for i := 0; i < maxLen; i++ {
				var lv, rv any
				var lExists, rExists bool

				if i < len(l) {
					lv = l[i]
					lExists = true
				}
				if i < len(r) {
					rv = r[i]
					rExists = true
				}

				switch {
				case lExists && !rExists:
					diffs = append(diffs, DiffResult{
						Path:  fmt.Sprintf("%s[%d]", path, i),
						Kind:  "removed",
						Left:  lv,
						Right: nil,
					})
				case !lExists && rExists:
					diffs = append(diffs, DiffResult{
						Path:  fmt.Sprintf("%s[%d]", path, i),
						Kind:  "added",
						Left:  nil,
						Right: rv,
					})
				case lExists && rExists:
					diffs = append(diffs, collectDiff(fmt.Sprintf("%s[%d]", path, i), lv, rv)...)
				}
			}
		} else {
			diffs = append(diffs, DiffResult{
				Path:  path,
				Kind:  "modified",
				Left:  left,
				Right: right,
			})
		}
	default:
		if fmt.Sprintf("%v", left) != fmt.Sprintf("%v", right) {
			diffs = append(diffs, DiffResult{
				Path:  path,
				Kind:  "modified",
				Left:  left,
				Right: right,
			})
		}
	}
	return diffs
}

func readJSON(r io.Reader) (map[string]any, error) {
	var data map[string]any
	decoder := json.NewDecoder(r)
	if err := decoder.Decode(&data); err != nil {
		return nil, err
	}
	return data, nil
}

func main() {
	flag.StringVar(&src_file, "src", "src.json", "source file")
	flag.StringVar(&dst_file, "dst", "dst.json", "destination file")
	flag.Parse()
	srcFile, err := os.Open(src_file)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error opening src.json: %v\n", err)
		return
	}
	defer srcFile.Close()

	dstFile, err := os.Open(dst_file)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error opening dst.json: %v\n", err)
		return
	}
	defer dstFile.Close()

	srcJson, err := readJSON(srcFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading src.json: %v\n", err)
		return
	}
	dstJson, err := readJSON(dstFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading dst.json: %v\n", err)
		return
	}
	diffs := collectDiff("", srcJson, dstJson)
	if len(diffs) == 0 {
		fmt.Println("No differences found.")
	} else {
		fmt.Printf("%d differences found:\n", len(diffs))
		for _, diff := range diffs {
			switch diff.Kind {
			case "added":
				fmt.Printf("Added: %s: %v\n", diff.Path, diff.Right)
			case "removed":
				fmt.Printf("Removed: %s: %v\n", diff.Path, diff.Left)
			case "modified":
				fmt.Printf("Modified: %s: %v -> %v\n", diff.Path, diff.Left, diff.Right)
			}
		}
	}
}
```

Test run, equally fast:

```bash
$ /usr/bin/time -f 'Elapsed Time: %e s Max RSS: %Mkbytes' ./diffjson -src ./src.json -dst ./dst.json
1 differences found:
Modified: timepicker.time_options[7]: 7d -> 7dd
Elapsed Time: 0.29 s Max RSS: 117468 kbytes
```
