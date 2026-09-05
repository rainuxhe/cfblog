+++
date = '2026-09-05T23:25:23+08:00'
lastmod = '2026-09-05T23:25:23+08:00'
draft = false
isCJKLanguage = true
title = 'Gin - 使用 sessions'
description = 'Gin 中如何使用 sessions 做认证'
summary = 'Gin 中如何使用 sessions 做认证，以及 cookies、内存存储和 Redis 存储的示例'
categories = ["program"]
tags = ["go", "gin"]
keywords = ["gin", "sessions"]
slug = 'how-to-use-sessions-in-gin'
+++

## 前言

HTTP 是无状态的，sessions 让服务能在多个请求之间保存同一用户的数据；服务端通过 cookie 等机制识别用户，取回其先前存储的数据。

`gin-contrib/sessions` 中间件提供支持多种存储后端的 session 管理能力。

```shell
go get github.com/gin-contrib/sessions
```

参考：[https://gin-gonic.com/en/docs/middleware/session-management/](https://gin-gonic.com/en/docs/middleware/session-management/)

## 概念

- cookie 型 session：session 数据序列化并签名加密后，整个塞到浏览器 cookie。服务端无状态、天然支持水平扩容；缺点是数据可见体积受限（~4KB）、**服务端无法主动吊销**（只能靠删 cookie 或引入服务端黑名单）、每次请求都传输整份数据。
- 服务端存储型：cookie 里只放一个随机 session ID，数据存在服务端。这类后端能真正“服务端登出”（删掉/过期掉 session 记录）。

## cookie 型示例

```go
package main

import (
	"net/http"
	"time"

	"github.com/gin-contrib/sessions"
	"github.com/gin-contrib/sessions/cookie"
	"github.com/gin-gonic/gin"
)

var (
	mockUsers = map[string]string{
		"zhangsan": "123456",
		"lisi":     "654321",
	}
	// secretKey = "your-secret-key"
	hmacSecretKey  = "5KiinhGcvoXFmgOttvgMWd9ugadE0KVP"
	blockSecretKey = "OLZmfTWHGyjCfJoH1Y8SjbSY"
)

const sessionTTL = 60 * 5

func sessionOptions(maxAge int) sessions.Options {
	return sessions.Options{
		Path:     "/",
		Domain:   "",                      // 设置为 "" 表示当前域名
		MaxAge:   maxAge,                  // 单位为秒。0 表示不写Max-Age(浏览器会话cookie); -1 表示删除 cookie
		Secure:   false,                   // 生产走 HTTPS 时改 true
		HttpOnly: true,                    // true 表示禁止 JS 读取 cookie
		SameSite: http.SameSiteStrictMode, // 严格模式，仅在同源请求中发送 cookie
	}
}

func main() {
	r := gin.Default()

	// Create cookie-based session store with a secret key
	// 传单个密钥时, 只做签名认证，不加密cookie内容. 认证密钥建议 32 或 64 字节
	// 传一对密钥时，第一个用于认证（HMAC），第二个用于加密（AES-128, AES-192, AES-256）。加密密钥必须是16、24或32字节长度，对应 AES-128/192/256。
	// 多对密钥用于密钥轮换，第一对用于当前加密和认证，后续的用于解密和认证旧的cookie。Example: cookie.NewStore([]byte("newAuth"), []byte("newEnc"), []byte("oldAuth"), []byte("oldEnc"))
	store := cookie.NewStore([]byte(hmacSecretKey), []byte(blockSecretKey))
	store.Options(sessionOptions(sessionTTL)) // 全局设置 cookie 过期时间为 5 分钟
	r.Use(sessions.Sessions("mysession", store))

	r.POST("/login", login)

	auth := r.Group("/", authRequired())
	{
		auth.GET("/profile", profile)
		auth.POST("/logout", logout)
	}

	r.Run(":8080")
}

func login(c *gin.Context) {
	session := sessions.Default(c)
	username := c.PostForm("username")
	password := c.PostForm("password")

	if username == "" || password == "" {
		c.JSON(http.StatusBadRequest, gin.H{"error": "username or password is empty"})
		return
	}

	if mockUsers[username] != password {
		c.JSON(http.StatusUnauthorized, gin.H{"error": "invalid username or password"})
		return
	}

	session.Set("user", username)
	session.Set("expire_at", time.Now().Add(time.Second*sessionTTL).Unix()) // 设置过期时间
	if err := session.Save(); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "save session failed"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "logged in"})
}

func logout(c *gin.Context) {
	session := sessions.Default(c)
	session.Clear()
	session.Options(sessionOptions(-1)) // 让浏览器删除 cookie
	if err := session.Save(); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "save session failed"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"message": "logged out"})
}

func profile(c *gin.Context) {
	session := sessions.Default(c)
	user := session.Get("user").(string)
	c.JSON(http.StatusOK, gin.H{"user": user})
}

func authRequired() gin.HandlerFunc {
	return func(c *gin.Context) {
		session := sessions.Default(c)
		if session.Get("user") == nil {
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "unauthorized"})
			return
		}

		if expireAt, ok := session.Get("expire_at").(int64); !ok || time.Now().Unix() > expireAt {
			session.Clear()
			session.Options(sessionOptions(-1))
			session.Save()
			c.AbortWithStatusJSON(http.StatusUnauthorized, gin.H{"error": "expired session"})
			return
		}
		c.Next()
	}
}
```

- `session.Delete(key)` 只删除一个 key 对应的条目
- `session.Clear()` 清空所有条目。适用于登出时整体作废。
- `sessions.Options` 中的 `SameSite` 用来控制跨域 cookie 行为，有 `Lax`, `Strict` 和 `None` 选项。

## 服务端内存型

服务端内存型就是把 session 存在服务的内存中，这种一般只适合本地**单实例**开发测试。服务一旦重启，所有 session 即失效，需要客户端重新登录。而且多个实例之间内存数据不共享，如果没有做粘性会话，可能会让客户端反复登录。

如果使用 `gin-contrib/sessions`，只需要在上面 cookie 型的基础上，将 `store` 替换掉即可。以下为需要的改动，其它的都不用改。

```go
import (
    // 引入 memstore
    "github.com/gin-contrib/sessions/memstore"
)

func main() {
    // 替换store类型
    store := memstore.NewStore([]byte(hmacSecretKey), []byte(blockSecretKey))
}
```

替换成服务端内存型后，登出的代码虽然没改，但是行为有所变化。在 cookie 型中，登出只是让浏览器把 cookie 删了；换成服务端内存型后，`session.Save()` 会额外把内存里的会话记录删了，让登出变得真正吊销了。

## Redis 后端型

类似上面的服务端内存型，只是把会话数据放到了 Redis 中，实现多实例之间共享会话数据，生产环境常用。

`redis.NewStore()` 的函数签名如下，其中 `size` 代表最大空闲连接数；`network` 应该为 `tcp` 或 `udp`；`address` 是 `host:port` 的格式。

```go
func redis.NewStore(size int, network string, address string, username string, password string, keyPairs ...[]byte) (redis.Store, error)
```


代码改动点:

```go
import (
    "github.com/gin-contrib/sessions/redis"
)

func main() {
    // 替换store类型
    // 第一个参数
    store, err := redis.NewStore(10, "tcp", "localhost:6379", "", "", []byte(hmacSecretKey), []byte(blockSecretKey))
}
```

### 客户端请求示例

以 `curl` 为例:

1. 登录

```shell
curl -X POST http://127.0.0.1:8080/login -d 'username=zhangsan&password=123456' -v
Note: Unnecessary use of -X or --request, POST is already inferred.
*   Trying 127.0.0.1:8080...
* Connected to 127.0.0.1 (127.0.0.1) port 8080
* using HTTP/1.x
> POST /login HTTP/1.1
> Host: 127.0.0.1:8080
> User-Agent: curl/8.14.1
> Accept: */*
> Content-Length: 33
> Content-Type: application/x-www-form-urlencoded
>
* upload completely sent off: 33 bytes
< HTTP/1.1 200 OK
< Content-Type: application/json; charset=utf-8
< Set-Cookie: mysession=MTc4ODYxOTIyNHwyN2FJTXR2QW5fQkVEMTJXa3dCUm96b0FxMWhmT0trTk15TG9LZmdSbjFxZk1pYjVHUjJabUZDTTBYTTJ6emFReG9FS0ZEQmVvY3c5aUgxQTdwSEJKd3lqOFQ5YnRVYUd8gZKrbW95srVahjgHg3FVThw6B1AXbJFseRs-DMIcp_w=; Path=/; Expires=Sat, 05 Sep 2026 14:45:24 GMT; Max-Age=300; HttpOnly; SameSite=Strict
< Date: Sat, 05 Sep 2026 14:40:24 GMT
< Content-Length: 23
<
* Connection #0 to host 127.0.0.1 left intact
{"message":"logged in"}
```

2. 请求 `/profile` API

```shell
# 不带cookie测试, 提示未认证
curl http://127.0.0.1:8080/profile
{"error":"unauthorized"}

# 带 cookie 测试
curl http://127.0.0.1:8080/profile -b 'mysession=MTc4ODYxOTIyNHwyN2FJTXR2QW5fQkVEMTJXa3dCUm96b0FxMWhmT0trTk15TG9LZmdSbjFxZk1pYjVHUjJabUZDTTBYTTJ6emFReG9FS0ZEQmVvY3c5aUgxQTdwSEJKd3lqOFQ5YnRVYUd8gZKrbW95srVahjgHg3FVThw6B1AXbJFseRs-DMIcp_w=; Path=/;Expires=Sat, 05 Sep 2026 14:45:24 GMT; Max-Age=300; HttpOnly; SameSite=Strict'
{"user":"zhangsan"}
```

3. 登出

```shell
curl -X POST http://127.0.0.1:8080/logout -b 'mysession=MTc4ODYxOTIyNHwyN2FJTXR2QW5fQkVEMTJXa3dCUm96b0FxMWhmT0trTk15TG9LZmdSbjFxZk1pYjVHUjJabUZDTTBYTTJ6emFReG9FS0ZEQmVvY3c5aUgxQTdwSEJKd3lqOFQ5YnRVYUd8gZKrbW95srVahjgHg3FVThw6B1AXbJFseRs-DMIcp_w=; Path=/; Expires=Sat, 05 Sep 2026 14:45:24 GMT; Max-Age=300; HttpOnly; SameSite=Strict'
{"message":"logged out"}
```

4. 再次请求 `/profile` 会提示未认证。

## 补充

### 其它存储类型

除了 `memstore` 和 `redis`，`gin-contrib/sessions` 还支持以下存储类型：

- `memcache`
- `mongodb`
- `postgres`
- `filesystem`

### Sessions vs JWT

| 对比方面 | 服务端存储型 Sessions       | JWT            |
| ---- | -------------- | -------------- |
| 存储   | 服务端（内存、Redis 等） | 客户端（token）     |
| 撤销   | 简单，从存储中删除即可    | 相对困难，一般需要设置黑名单 |
| 可扩展性 | 需要共享存储         | 无状态            |
| 数据大小 | 服务端无限制        | 受令牌大小限制        |

Web 应用一般优先用 session，HttpOnly 和 SameSite 机制可以一定程度上保障安全。JWT 主要面向微服务间认证。

cookie 型 sessions 也是无状态的，有点类似 JWT。区别在于 cookie 内容都是加密的（如果使用了双密钥），客户端读不出来也改不了。而 JWT 的 payload 可以被任何人看到，只是改不了。cookie 对用户来说是不透明令牌，而 JWT 对客户端来说是自描述令牌。因此 JWT 中不适合存放任何敏感数据，连 `"user": "username"` 这样的信息也不要有（一般可以写成 "uid": "abcd"，避免直接暴露用户信息）。

cookie 借助浏览器，天然获得 `HttpOnly`，可以防 XSS（跨站脚本攻击），但引入 CSRF 风险，需要设置 `SameSite` 来抵御。JWT 如果放 `localStorage`，XSS 能直接偷走，但请求靠 JS 手动加 `Authorization` 请求头，没有 CSRF 问题。

要撤销 JWT，除了加黑名单（服务验证签名后，再到共享存储中查一下 token 在不在黑名单中。设置黑名单时，一般设置 TTL 为 token 的剩余时长。），一般还有双 Token 验证机制：长期的 refresh token 和短期的 access token，只有 refresh token 需要黑名单机制，access token 还是无状态的。（以后展开具体说，这里不再详述。）

在移动 App 中，因为 App 没有类似浏览器的 cookie 机制，直接用 JWT。

前后端分离的项目中，使用 sessions 和 JWT 都要注意跨域问题。