+++
date = '2026-05-31T00:07:52+08:00'
draft = false
title = 'Python - argparse Standard Library Usage'
description = 'Python Argparse Usage'
summary = 'Introduction to Python argparse standard library'
categories = ["program"]
tags = ["python", "AI-Translated"]
keywords = ["python", "argparse"]
slug = 'python-argparse-usage'
+++

## Introduction

`argparse` is a module in the Python standard library used for parsing command-line arguments.

## Basic Usage

```python
import argparse

# Create parser
## description: Program description
## prog: Program name, defaults to script name
## epilog: Additional text at the end of help message
## formatter_class: Controls help message display style
parser = argparse.ArgumentParser(
    prog="/my_tool",
    description="A simple command-line tool.",
    epilog="Example usage: /my_tool 'Hello World' --verbose"
)

# Use add_argument() to add arguments
# echo1 and echo2 are positional arguments, must be provided in order
# type specifies type conversion function
# help sets the help description
parser.add_argument("echo1", type=str, help="echo something")
parser.add_argument("echo2", type=str, help="echo something")

# -x or --xx are optional arguments
# default sets the default value
parser.add_argument("--sftp_ip",type=str,default="127.0.0.1", help="SFTP server IP address")

# Auto-convert type to int
# metavar modifies the placeholder name in help text
parser.add_argument("--sftp_port", metavar="PORT", type=int, default="22")

# dest specifies the attribute name after parsing; use args.username to access
parser.add_argument("--user-name", dest="username")

# required makes an optional argument mandatory
# required only applies to optional arguments
parser.add_argument("--name", required=True)

# choice restricts the range of acceptable values
parser.add_argument("-H","--host",type=str, choices=["127.0.0.1", "192.168.0.10"])

# nargs controls the number of arguments
## nargs=2, exactly 2 arguments required
## nargs='*', 0 or more arguments
## nargs='+', 1 or more arguments
## nargs='?', 0 or 1 argument
parser.add_argument('--nums', nargs=3, type=int)


# Create mutually exclusive group; -v and -q cannot be used together
group = parser.add_mutually_exclusive_group()
# action defines the argument's behavior
group.add_argument("-v", "--verbose", action="store_true")
group.add_argument("-q", "--quiet", action="store_true")

# Parse arguments
# Returns a Namespace object
args = parser.parse_args()

# Use command arguments
print(f"echo1: {args.echo1}, echo2: {args.echo2}")
print(f"SFTP IP: {args.sftp_ip}, Port: {args.sftp_port}")
print(f"host is {args.host}")
```

argparse automatically generates help options `-h` and `--help`.

## The action Parameter

The `action` parameter in `add_argument()` defines the argument's behavior. The default value is `store`.

- `action='store_true'`, commonly used for boolean flags, defaults to `False`

```python
parser.add_argument('--verbose', action='store_true')

# Run python app.py --verbose
# After parsing
args.verbose == True
```

- `action='store_false'`, inverse boolean flag
- `action='append'`, appends to a list each time it appears

```python
parser.add_argument('--tag', action='append')

# Usage
python app.py --tag a --tag b

# Result
args.tag == ['a', 'b']
```

- `action='count'`, counts occurrences

```python
parser.add_argument('-v', '--verbose', action='count', default=0)

# Usage
python app.py -vvv

# Result
args.verbose == 3
```

- `action='version'`, prints version

```python
parser.add_argument('--version', action='version', version='v1.0.0', default=0)

# Usage
python app.py --version
# Output: v1.0.0

# Can also use a function to dynamically get version
def get_version() -> str:
    return "v1.0.0"

# If help is not provided, defaults to "show program's version number and exit"
parser.add_argument(
    "--version",
    action="version",
    version=get_version(),
)
```

- `action='store_const'`, sets to a specified value

```python
parser.add_argument('--json', action='store_const', const='json', dest='format')

# Run
python app.py --json

# Result
args.format == 'json'
```

## Mutually Exclusive Arguments

Create a mutually exclusive group: `group = parser.add_mutually_exclusive_group()`

Arguments added via `group.add_argument` are mutually exclusive and cannot be used together.

Simple example:

```python
import argparse

parser = argparse.ArgumentParser()

# Create mutually exclusive group
# If required=True is passed, the user must choose one from the group; defaults to optional
group = parser.add_mutually_exclusive_group()

group.add_argument('--verbose', action='store_true')
group.add_argument('--quiet', action='store_true')

args = parser.parse_args()
print(args)

# Using both will cause an error
python app.py --verbose --quiet
```

## Subcommands

When a command-line tool includes multiple operations, subcommands may be needed, for example:

```shell
python tool.py add user1
python tool.py delete user1
python tool.py list
```

Here `add`, `delete`, and `list` are all subcommands. The best approach is to use `parser.add_subparsers()`.

`add_subparsers()` adds **multiple subparsers** to a command-line program, each corresponding to a subcommand.

### Basic Usage

```python
import argparse

parser = argparse.ArgumentParser(prog='usercli', description='User management tool')
# required=True forces the user to use a subcommand
# It's recommended to always explicitly write dest='command'
subparsers = parser.add_subparsers(dest='command', required=True)

# add subcommand
parser_add = subparsers.add_parser('add', help='Add user')
parser_add.add_argument('username', help='Username')
parser_add.add_argument('--age', type=int, default=18, help='Age')

# delete subcommand
parser_delete = subparsers.add_parser('delete', help='Delete user')
parser_delete.add_argument('username', help='Username')

# list subcommand
parser_list = subparsers.add_parser('list', help='List users')
parser_list.add_argument('--verbose', action='store_true', help='Show details')

args = parser.parse_args()

if args.command == 'add':
    print(f'Adding user: {args.username}, Age: {args.age}')
elif args.command == 'delete':
    print(f'Deleting user: {args.username}')
elif args.command == 'list':
    print(f'Listing users, verbose={args.verbose}')
```

### Binding Handler Functions to Subcommands

Using `if/elif` for dispatching works for simple cases, but becomes messy when there are many commands with complex functionality. In such cases, you can bind handler functions to subcommands.

Example code:

```python
import argparse

def handle_add(args):
    print(f'Adding user: {args.username}, Age: {args.age}')

def handle_delete(args):
    print(f'Deleting user: {args.username}')

def handle_list(args):
    print(f'Listing users, verbose={args.verbose}')

def create_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog='usercli')
    subparsers = parser.add_subparsers(dest='command', required=True)

    parser_add = subparsers.add_parser('add', help='Add user')
    parser_add.add_argument('username')
    parser_add.add_argument('--age', type=int, default=18)
    parser_add.set_defaults(func=handle_add)

    parser_delete = subparsers.add_parser('delete', help='Delete user')
    parser_delete.add_argument('username')
    parser_delete.set_defaults(func=handle_delete)

    parser_list = subparsers.add_parser('list', help='List users')
    parser_list.add_argument('--verbose', action='store_true')
    parser_list.set_defaults(func=handle_list)
    return parser

def main() -> None:
    parser = create_parser()
    args = parser.parse_args()
    args.func(args)

if __name__ == "__main__":
    main()
```

### Sharing Common Parameters Across Subcommands

If multiple subcommands need the same set of parameters, you can create a "parent parser."

```python
import argparse

def main():
    common_parser = argparse.ArgumentParser(add_help=False)
    common_parser.add_argument('--config', help='Config file path')

    parser = argparse.ArgumentParser(prog='tool')
    subparsers = parser.add_subparsers(dest='command', required=True)

    parser_a = subparsers.add_parser('start', parents=[common_parser])
    parser_a.add_argument('--port', type=int)

    parser_b = subparsers.add_parser('stop', parents=[common_parser])
    parser_b.add_argument('--force', action='store_true')

    args = parser.parse_args()
    if args.command == 'start':
        print(f"Starting with config: {args.config} on port: {args.port}")
    elif args.command == 'stop':
        print(f"Stopping with config: {args.config} {'forcefully' if args.force else ''}")
    else:
        print("Unknown command")

if __name__ == "__main__":
    main()
```

### Setting Aliases for Subcommands

```python
parser_remove = subparsers.add_parser('remove', aliases=['rm'])
```

This allows both forms:

```shell
python tool.py remove file.txt
python tool.py rm file.txt
```

### Nested Subcommands

Complex CLIs may have multiple levels of commands, for example:

```bash
tool user add alice
tool user delete bob
```

You can nest `add_subparsers()`:

```python
import argparse

parser = argparse.ArgumentParser(prog='tool')
subparsers = parser.add_subparsers(dest='entity', required=True)

user_parser = subparsers.add_parser('user')
user_subparsers = user_parser.add_subparsers(dest='action', required=True)

user_add = user_subparsers.add_parser('add')
user_add.add_argument('name')

user_delete = user_subparsers.add_parser('delete')
user_delete.add_argument('name')

args = parser.parse_args()
print(args)
```

Run:

```bash
python tool.py user add alice
```

Result:

```python
Namespace(entity='user', action='add', name='alice')
```
