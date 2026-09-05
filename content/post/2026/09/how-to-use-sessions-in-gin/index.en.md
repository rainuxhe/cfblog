+++
date = '2026-09-05T23:25:23+08:00'
lastmod = '2026-09-05T23:25:23+08:00'
draft = false
isCJKLanguage = false
title = 'Gin - Using Sessions'
description = 'How to use sessions for authentication in Gin'
summary = 'Authentication with Gin sessions: cookie-based, in-memory, and Redis-backed examples'
categories = ["program"]
tags = ["go", "gin", "AI-Translated"]
keywords = ["gin", "sessions"]
slug = 'how-to-use-sessions-in-gin'
+++

## Introduction

HTTP is stateless, so sessions let the server keep a particular user's data across requests. The server identifies the user through a cookie or similar mechanism and hands back whatever was stored earlier.

`gin-contrib/sessions` provides session management with pluggable storage backends.

```shell
go get github.com/gin-contrib/sessions
```

Reference: [https://gin-gonic.com/en/docs/middleware/session-management/](https://gin-gonic.com/en/docs/middleware/session-management/)

## Concepts

- **Cookie-based sessions.** The session data is serialized, signed, and encrypted, then stuffed wholesale into a browser cookie. The server stays stateless, so horizontal scaling comes for free. The downsides: the payload is capped at roughly 4KB, **the server can't revoke a session unilaterally** (you can only delete the cookie or keep a server-side denylist), and the whole blob is shipped with every single request.
- **Server-side stores.** The cookie only carries a random session ID; the data lives on the server. These backends enable true server-side logout — just delete or expire the session record.

## Cookie-Based Sessions

Here's a complete, runnable example using the cookie store:

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
		Domain:   "",                      // "" = current domain
		MaxAge:   maxAge,                  // seconds; 0 = no Max-Age (session cookie), -1 = delete cookie
		Secure:   false,                   // flip to true once you're behind HTTPS
		HttpOnly: true,                    // true = JS can't read the cookie
		SameSite: http.SameSiteStrictMode, // Strict: only send the cookie on same-site requests
	}
}

func main() {
	r := gin.Default()

	// A single key only signs the cookie, without encrypting it. Auth keys should be 32 or 64 bytes.
	// With a key pair, the first key authenticates (HMAC) and the second encrypts (AES-128/192/256). The encryption key must be 16, 24, or 32 bytes for AES-128/192/256 respectively.
	// Extra key pairs enable rotation: the first pair encrypts & authenticates new cookies, and the rest only decrypt & verify older ones. Example: cookie.NewStore([]byte("newAuth"), []byte("newEnc"), []byte("oldAuth"), []byte("oldEnc"))
	store := cookie.NewStore([]byte(hmacSecretKey), []byte(blockSecretKey))
	store.Options(sessionOptions(sessionTTL)) // expire all cookies after 5 minutes
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
	session.Set("expire_at", time.Now().Add(time.Second*sessionTTL).Unix()) // store the expiry time
	if err := session.Save(); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "save session failed"})
		return
	}

	c.JSON(http.StatusOK, gin.H{"message": "logged in"})
}

func logout(c *gin.Context) {
	session := sessions.Default(c)
	session.Clear()
	session.Options(sessionOptions(-1)) // ask the browser to delete the cookie
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

- `session.Delete(key)` removes a single key from the session.
- `session.Clear()` empties the whole session — handy for logging out.
- `SameSite` in `sessions.Options` controls cross-site cookie behavior. Options are `Lax`, `Strict`, and `None`.

## In-Memory Store

An in-memory store keeps session data in the server's RAM, which really only suits local, single-instance development and testing. Restart the server and every session dies with it — clients have to log in again. And since memory isn't shared between instances, without sticky sessions you'd keep bouncing users back to the login page.

With `gin-contrib/sessions`, just swap the store and leave everything else from the cookie example untouched. Here's the entire diff:

```go
import (
	// import memstore
	"github.com/gin-contrib/sessions/memstore"
)

func main() {
	// swap the store type
	store := memstore.NewStore([]byte(hmacSecretKey), []byte(blockSecretKey))
}
```

The logout code stays the same, but its behavior changes. With cookie-based sessions, logging out only tells the browser to drop the cookie. With the in-memory store, `session.Save()` additionally deletes the in-memory record, so logout genuinely revokes the session.

## Redis Store

Same idea as the in-memory store, except the session data lives in Redis. Multiple instances then share the same sessions, which makes this the usual pick for production.

`redis.NewStore()` has the signature below. `size` is the maximum number of idle connections, `network` should be `tcp` or `udp`, and `address` takes the `host:port` form.

```go
func redis.NewStore(size int, network string, address string, username string, password string, keyPairs ...[]byte) (redis.Store, error)
```

What changes:

```go
import (
	"github.com/gin-contrib/sessions/redis"
)

func main() {
	// swap the store type
	// the first argument is the max idle connections
	store, err := redis.NewStore(10, "tcp", "localhost:6379", "", "", []byte(hmacSecretKey), []byte(blockSecretKey))
}
```

### Sample Requests with curl

A quick walkthrough with `curl`:

1. Log in

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

2. Hit the `/profile` API

```shell
# without the cookie → unauthorized
curl http://127.0.0.1:8080/profile
{"error":"unauthorized"}

# with the cookie
curl http://127.0.0.1:8080/profile -b 'mysession=MTc4ODYxOTIyNHwyN2FJTXR2QW5fQkVEMTJXa3dCUm96b0FxMWhmT0trTk15TG9LZmdSbjFxZk1pYjVHUjJabUZDTTBYTTJ6emFReG9FS0ZEQmVvY3c5aUgxQTdwSEJKd3lqOFQ5YnRVYUd8gZKrbW95srVahjgHg3FVThw6B1AXbJFseRs-DMIcp_w=; Path=/;Expires=Sat, 05 Sep 2026 14:45:24 GMT; Max-Age=300; HttpOnly; SameSite=Strict'
{"user":"zhangsan"}
```

3. Log out

```shell
curl -X POST http://127.0.0.1:8080/logout -b 'mysession=MTc4ODYxOTIyNHwyN2FJTXR2QW5fQkVEMTJXa3dCUm96b0FxMWhmT0trTk15TG9LZmdSbjFxZk1pYjVHUjJabUZDTTBYTTJ6emFReG9FS0ZEQmVvY3c5aUgxQTdwSEJKd3lqOFQ5YnRVYUd8gZKrbW95srVahjgHg3FVThw6B1AXbJFseRs-DMIcp_w=; Path=/; Expires=Sat, 05 Sep 2026 14:45:24 GMT; Max-Age=300; HttpOnly; SameSite=Strict'
{"message":"logged out"}
```

4. Hit `/profile` again and you'll get `unauthorized`.

## More

### Other Store Backends

Besides `memstore` and `redis`, `gin-contrib/sessions` also ships these storage backends:

- `memcache`
- `mongodb`
- `postgres`
- `filesystem`

### Sessions vs JWT

| Aspect         | Server-side Sessions        | JWT              |
| -------------- | --------------------------- | ---------------- |
| Storage        | Server side (memory, Redis, etc.) | Client side (the token) |
| Revocation     | Easy — just delete the stored record | Hard — usually needs a denylist |
| Scalability    | Needs shared storage        | Stateless        |
| Data size      | Unlimited on the server     | Bounded by token size |

For classic web apps, sessions are usually the first choice — `HttpOnly` and `SameSite` already provide a decent security baseline. JWT, on the other hand, is aimed at service-to-service authentication.

Cookie-based sessions are stateless too, which makes them similar to JWT. The difference: cookie contents are encrypted (when you pass a key pair), so clients can neither read nor tamper with them. A JWT payload can be decoded and read by anyone — it just can't be modified. To the client, a cookie is an opaque token, while a JWT is self-describing. That's why you shouldn't put sensitive data in a JWT at all — not even something like `"user": "username"`. A claim such as `"uid": "abcd"` is fine because it doesn't reveal who the user is.

Cookies ride on the browser, so `HttpOnly` comes for free and helps against XSS (cross-site scripting), but they introduce CSRF risk, which you mitigate with `SameSite`. A JWT stored in `localStorage` can be stolen directly by XSS; since requests carry it in an `Authorization` header added manually by JS, though, CSRF isn't a concern.

Revoking a JWT takes more work than sessions. Beyond a denylist (verify the signature, then check the shared store for the token — and set the denylist entry's TTL to the token's remaining lifetime), the common approach is a two-token scheme: a long-lived refresh token and a short-lived access token. Only the refresh token needs the denylist; the access token stays stateless. (I'll expand on this in a future post.)

In mobile apps there's no browser-style cookie machinery, so JWT is the default choice.

And in projects with a separated front end and back end, mind the cross-origin issues whether you go with sessions or JWT.
