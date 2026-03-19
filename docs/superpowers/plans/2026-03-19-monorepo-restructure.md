# Caido MCP Server - Monorepo Restructure

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge CLI and MCP server into a single Go module with shared packages, fix all bugs from code review.

**Architecture:** Single `go.mod` with two binaries (`cmd/mcp/`, `cmd/cli/`). Shared logic in `internal/httputil/` (HTTP parsing, URL building, CRLF) and `internal/replay/` (session management, polling). Auth package gets atomic writes and URL validation.

**Tech Stack:** Go 1.24, cobra, caido-community/sdk-go v0.2.2, modelcontextprotocol/go-sdk v1.2.0

---

## File Structure (Target)

```
/
cmd/
  mcp/
    main.go          # MCP entry (from /main.go)
    root.go          # cobra root (from /cmd/root.go)
    serve.go         # serve command (from /cmd/serve.go)
    login.go         # login command (from /cmd/login.go)
  cli/
    main.go          # CLI entry (from Caido-CLI/main.go)
    client.go        # client setup (from Caido-CLI/client.go, trimmed)
    send.go          # structured send (from Caido-CLI/send.go)
    raw.go           # raw send (from Caido-CLI/raw.go)
    history.go       # history list (from Caido-CLI/history.go, trimmed)
    request.go       # request details (from Caido-CLI/request.go)
    replay.go        # replay helpers (from Caido-CLI/replay.go, trimmed)
    format.go        # output formatting (from Caido-CLI/format.go, trimmed)
    status.go        # status check (from Caido-CLI/status.go)
    encode.go        # encode/decode (from Caido-CLI/encode.go)
internal/
  auth/
    oauth.go         # MODIFIED: URL validation in openBrowser
    token_store.go   # MODIFIED: atomic writes
  httputil/
    parse.go         # NEW: shared HTTP parsing (ordered headers)
    url.go           # NEW: shared buildURL
    crlf.go          # NEW: shared CRLF normalization + host parsing + consts
    parse_test.go    # NEW
    url_test.go      # NEW
    crlf_test.go     # NEW
  replay/
    replay.go        # NEW: shared session mgmt + polling
    replay_test.go   # NEW
  tools/
    http_utils.go    # DELETE (replaced by internal/httputil)
    *.go             # MODIFIED: updated imports
scripts/
  build.sh           # MODIFIED: ldflags version + new paths
install.sh           # UNCHANGED
```

---

### Task 1: Create shared httputil package

**Files:**
- Create: `internal/httputil/parse.go`
- Create: `internal/httputil/parse_test.go`
- Create: `internal/httputil/url.go`
- Create: `internal/httputil/url_test.go`
- Create: `internal/httputil/crlf.go`
- Create: `internal/httputil/crlf_test.go`

- [ ] **Step 1: Write parse.go**

Key changes from old `http_utils.go`: `Headers` is `[]Header` (ordered, preserves duplicates) instead of `map[string]string`. Exports `DefaultBodyLimit = 2000`.

```go
package httputil

import (
    "bufio"
    "bytes"
    "encoding/base64"
    "io"
    "strings"
)

const DefaultBodyLimit = 2000

type Header struct {
    Name  string `json:"name"`
    Value string `json:"value"`
}

type ParsedMessage struct {
    FirstLine string   `json:"firstLine,omitempty"`
    Headers   []Header `json:"headers,omitempty"`
    Body      string   `json:"body,omitempty"`
    BodySize  int      `json:"bodySize,omitempty"`
    Truncated bool     `json:"truncated,omitempty"`
}

func ParseBase64(
    raw string,
    includeHeaders, includeBody bool,
    bodyOffset, bodyLimit int,
) *ParsedMessage {
    if raw == "" {
        return nil
    }
    decoded, err := base64.StdEncoding.DecodeString(raw)
    if err != nil {
        return nil
    }
    return ParseRaw(decoded, includeHeaders, includeBody, bodyOffset, bodyLimit)
}

func ParseRaw(
    raw []byte,
    includeHeaders, includeBody bool,
    bodyOffset, bodyLimit int,
) *ParsedMessage {
    result := &ParsedMessage{}
    parts := bytes.SplitN(raw, []byte("\r\n\r\n"), 2)
    headerPart := parts[0]
    var bodyPart []byte
    if len(parts) > 1 {
        bodyPart = parts[1]
    }

    if includeHeaders {
        reader := bufio.NewReader(bytes.NewReader(headerPart))
        firstLine, err := reader.ReadString('\n')
        if err == nil || err == io.EOF {
            result.FirstLine = strings.TrimSpace(firstLine)
        }
        for {
            line, err := reader.ReadString('\n')
            if err != nil {
                break
            }
            line = strings.TrimSpace(line)
            if line == "" {
                break
            }
            if idx := strings.Index(line, ":"); idx > 0 {
                result.Headers = append(result.Headers, Header{
                    Name:  strings.TrimSpace(line[:idx]),
                    Value: strings.TrimSpace(line[idx+1:]),
                })
            }
        }
    }

    result.BodySize = len(bodyPart)
    if includeBody && len(bodyPart) > 0 {
        if bodyOffset > 0 {
            if bodyOffset >= len(bodyPart) {
                bodyPart = []byte{}
            } else {
                bodyPart = bodyPart[bodyOffset:]
            }
        }
        if bodyLimit > 0 && len(bodyPart) > bodyLimit {
            bodyPart = bodyPart[:bodyLimit]
            result.Truncated = true
        }
        result.Body = string(bodyPart)
    }

    return result
}
```

- [ ] **Step 2: Write parse_test.go**

Test: duplicate headers preserved, body truncation, base64 decode, empty input returns nil.

- [ ] **Step 3: Write url.go**

```go
package httputil

import "fmt"

func BuildURL(isTLS bool, host string, port int, path, query string) string {
    scheme := "http"
    if isTLS {
        scheme = "https"
    }
    u := fmt.Sprintf("%s://%s", scheme, host)
    if (isTLS && port != 443) || (!isTLS && port != 80) {
        u = fmt.Sprintf("%s:%d", u, port)
    }
    u += path
    if query != "" {
        u += "?" + query
    }
    return u
}
```

- [ ] **Step 4: Write url_test.go**

- [ ] **Step 5: Write crlf.go**

```go
package httputil

import "strings"

func NormalizeCRLF(raw string) string {
    raw = strings.ReplaceAll(raw, `\r\n`, "\r\n")
    raw = strings.ReplaceAll(raw, "\r\n", "\n")
    raw = strings.ReplaceAll(raw, "\n", "\r\n")
    if !strings.HasSuffix(raw, "\r\n\r\n") {
        if strings.HasSuffix(raw, "\r\n") {
            raw += "\r\n"
        } else {
            raw += "\r\n\r\n"
        }
    }
    return raw
}

func ParseHostHeader(raw string) string {
    for _, line := range strings.Split(raw, "\n") {
        line = strings.TrimSpace(line)
        if strings.HasPrefix(strings.ToLower(line), "host:") {
            return strings.TrimSpace(line[5:])
        }
    }
    return ""
}
```

- [ ] **Step 6: Write crlf_test.go**

- [ ] **Step 7: Run tests**

Run: `go test ./internal/httputil/ -v`
Expected: all pass

- [ ] **Step 8: Commit**

```
git add internal/httputil/
git commit -m "feat: add shared httputil package"
```

---

### Task 2: Create shared replay package

**Files:**
- Create: `internal/replay/replay.go`
- Create: `internal/replay/replay_test.go`

- [ ] **Step 1: Write replay.go**

Exports: `GetOrCreateSession`, `ResetDefaultSession`, `PollForEntry`, `PollInterval`, `PollMaxRetries`.

```go
package replay

import (
    "context"
    "fmt"
    "sync"
    "time"

    caido "github.com/caido-community/sdk-go"
    gen "github.com/caido-community/sdk-go/graphql"
)

const (
    PollInterval   = 500 * time.Millisecond
    PollMaxRetries = 20
)

var (
    defaultSessionID string
    sessionMu        sync.Mutex
)

func GetOrCreateSession(
    ctx context.Context, client *caido.Client, inputID string,
) (string, error) {
    if inputID != "" {
        return inputID, nil
    }
    sessionMu.Lock()
    defer sessionMu.Unlock()
    if defaultSessionID != "" {
        return defaultSessionID, nil
    }
    resp, err := client.Replay.CreateSession(
        ctx, &gen.CreateReplaySessionInput{},
    )
    if err != nil {
        return "", fmt.Errorf("create replay session: %w", err)
    }
    defaultSessionID = resp.CreateReplaySession.Session.Id
    return defaultSessionID, nil
}

func ResetDefaultSession(newID string) {
    sessionMu.Lock()
    defaultSessionID = newID
    sessionMu.Unlock()
}

func PollForEntry(
    ctx context.Context,
    client *caido.Client,
    sessionID, prevEntryID string,
) (*gen.GetReplayEntryReplayEntry, error) {
    for i := 0; i < PollMaxRetries; i++ {
        sessResp, err := client.Replay.GetSession(ctx, sessionID)
        if err != nil {
            return nil, fmt.Errorf("poll session: %w", err)
        }
        sess := sessResp.ReplaySession
        if sess != nil && sess.ActiveEntry != nil &&
            sess.ActiveEntry.Id != prevEntryID {
            entryResp, err := client.Replay.GetEntry(
                ctx, sess.ActiveEntry.Id,
            )
            if err != nil {
                return nil, fmt.Errorf("poll entry: %w", err)
            }
            e := entryResp.ReplayEntry
            if e != nil && e.Request != nil &&
                e.Request.Response != nil {
                return e, nil
            }
        }
        select {
        case <-ctx.Done():
            return nil, ctx.Err()
        case <-time.After(PollInterval):
        }
    }
    return nil, fmt.Errorf(
        "timed out after %ds waiting for response",
        PollMaxRetries/2,
    )
}
```

- [ ] **Step 2: Write replay_test.go** (unit test for session caching logic)

- [ ] **Step 3: Run tests**

Run: `go test ./internal/replay/ -v`

- [ ] **Step 4: Commit**

```
git commit -m "feat: add shared replay package"
```

---

### Task 3: Fix auth package

**Files:**
- Modify: `internal/auth/token_store.go:55-68` (atomic writes)
- Modify: `internal/auth/oauth.go:370-388` (URL validation in openBrowser)

- [ ] **Step 1: Add atomic write to Save()**

Replace `os.WriteFile` with write-to-temp + `os.Rename`:

```go
func (s *TokenStore) Save(token *StoredToken) error {
    if err := s.ensureConfigDir(); err != nil {
        return err
    }
    data, err := json.MarshalIndent(token, "", "  ")
    if err != nil {
        return fmt.Errorf("failed to marshal token: %w", err)
    }
    tmpPath := s.tokenFilePath() + ".tmp"
    if err := os.WriteFile(tmpPath, data, filePermission); err != nil {
        return fmt.Errorf("failed to write token file: %w", err)
    }
    if err := os.Rename(tmpPath, s.tokenFilePath()); err != nil {
        return fmt.Errorf("failed to rename token file: %w", err)
    }
    return nil
}
```

- [ ] **Step 2: Add URL validation to openBrowser()**

```go
func openBrowser(rawURL string) error {
    u, err := url.Parse(rawURL)
    if err != nil {
        return fmt.Errorf("invalid URL: %w", err)
    }
    if u.Scheme != "http" && u.Scheme != "https" {
        return fmt.Errorf("refused to open non-HTTP URL: %s", u.Scheme)
    }
    // ... rest unchanged
}
```

- [ ] **Step 3: Verify build**

Run: `go build ./...`

- [ ] **Step 4: Commit**

```
git commit -m "fix: atomic token writes, validate openBrowser URL scheme"
```

---

### Task 4: Restructure directories

This is one atomic operation - move all files, update package declarations, update imports.

**Moves:**
- `main.go` -> `cmd/mcp/main.go` (rewrite: remove import, call Execute() directly)
- `cmd/root.go` -> `cmd/mcp/root.go` (change `package cmd` to `package main`)
- `cmd/serve.go` -> `cmd/mcp/serve.go` (change `package cmd` to `package main`)
- `cmd/login.go` -> `cmd/mcp/login.go` (change `package cmd` to `package main`)
- `Caido-CLI/*.go` -> `cmd/cli/*.go` (no package change needed, already `package main`)

**Deletes:**
- `Caido-CLI/go.mod`
- `Caido-CLI/go.sum`

- [ ] **Step 1: Create directories**

```bash
mkdir -p cmd/mcp cmd/cli
```

- [ ] **Step 2: Move MCP server files**

```bash
git mv main.go cmd/mcp/main.go
git mv cmd/root.go cmd/mcp/root.go
git mv cmd/serve.go cmd/mcp/serve.go
git mv cmd/login.go cmd/mcp/login.go
```

- [ ] **Step 3: Update cmd/mcp/main.go**

Remove the cmd package import, call Execute() directly:

```go
package main

func main() {
    Execute()
}
```

- [ ] **Step 4: Update package declarations in cmd/mcp/**

Change all three files from `package cmd` to `package main`.

- [ ] **Step 5: Move CLI files**

```bash
git mv Caido-CLI/main.go cmd/cli/main.go
git mv Caido-CLI/client.go cmd/cli/client.go
git mv Caido-CLI/send.go cmd/cli/send.go
git mv Caido-CLI/raw.go cmd/cli/raw.go
git mv Caido-CLI/history.go cmd/cli/history.go
git mv Caido-CLI/request.go cmd/cli/request.go
git mv Caido-CLI/replay.go cmd/cli/replay.go
git mv Caido-CLI/format.go cmd/cli/format.go
git mv Caido-CLI/status.go cmd/cli/status.go
git mv Caido-CLI/encode.go cmd/cli/encode.go
```

- [ ] **Step 6: Remove CLI's separate module**

```bash
git rm Caido-CLI/go.mod Caido-CLI/go.sum
```

- [ ] **Step 7: Run go mod tidy and verify build**

```bash
go mod tidy
go build ./cmd/mcp && go build ./cmd/cli
```

- [ ] **Step 8: Commit**

```
git commit -m "refactor: monorepo - merge CLI into single Go module"
```

---

### Task 5: Wire MCP tools to shared httputil

**Files:**
- Delete: `internal/tools/http_utils.go`
- Modify: `internal/tools/get_request.go` - use `httputil.ParseBase64`, `httputil.ParsedMessage`, `httputil.Header`, `httputil.DefaultBodyLimit`
- Modify: `internal/tools/list_requests.go` - use `httputil.BuildURL`
- Modify: `internal/tools/get_replay_entry.go` - use shared types
- Modify: `internal/tools/get_automate_entry.go` - use `httputil.BuildURL`
- Modify: `internal/tools/get_automate_session.go` - no change
- Modify: `internal/tools/send_request.go` - use shared httputil + replay
- Modify: `internal/tools/create_finding.go` - no change

Key type mapping:
- `ParsedHTTPMessage` -> `httputil.ParsedMessage`
- `parseHTTPMessage()` -> `httputil.ParseBase64()`
- `buildURL()` -> `httputil.BuildURL()`
- Magic `2000` -> `httputil.DefaultBodyLimit`

- [ ] **Step 1: Delete http_utils.go**

- [ ] **Step 2: Update imports in all tool files**

Add `"github.com/c0tton-fluff/caido-mcp-server/internal/httputil"` where needed.

- [ ] **Step 3: Replace all references**

- `*ParsedHTTPMessage` -> `*httputil.ParsedMessage`
- `parseHTTPMessage(...)` -> `httputil.ParseBase64(...)`
- `buildURL(...)` -> `httputil.BuildURL(...)`
- `bodyLimit = 2000` -> `bodyLimit = httputil.DefaultBodyLimit`

- [ ] **Step 4: Update send_request.go to use shared replay + httputil**

Replace local session/polling code with:
- `createOrReuseSession()` -> `replay.GetOrCreateSession()`
- `pollForResponse()` -> `replay.PollForEntry()`
- `parseHostFromRequest()` -> `httputil.ParseHostHeader()`
- CRLF normalization block -> `httputil.NormalizeCRLF()`
- Remove local `defaultSessionID`/`sessionMu` vars

- [ ] **Step 5: Verify build**

Run: `go build ./cmd/mcp`

- [ ] **Step 6: Commit**

```
git commit -m "refactor: MCP tools use shared httputil and replay packages"
```

---

### Task 6: Wire CLI to shared packages

**Files:**
- Modify: `cmd/cli/client.go` - use `internal/auth` for token loading
- Modify: `cmd/cli/history.go` - use `httputil.BuildURL`, remove local `buildURL`
- Modify: `cmd/cli/replay.go` - use shared replay + httputil, remove duplicated functions
- Modify: `cmd/cli/format.go` - use `httputil.ParseBase64`, remove local `parseRawBase64`
- Modify: `cmd/cli/request.go` - use shared format functions

- [ ] **Step 1: Update client.go to use internal/auth**

Replace inline `storedToken` and `loadToken()` with `auth.NewTokenStore()` + `tokenStore.Load()`.
Replace inline token refresh with `auth.RefreshAndSave()`.

- [ ] **Step 2: Update history.go**

Remove local `buildURL`, import and use `httputil.BuildURL`.

- [ ] **Step 3: Update replay.go**

Remove: `normalizeCRLF`, `parseHostHeader`, `getOrCreateSession`, `pollForEntry`, local session vars.
Import and use: `httputil.NormalizeCRLF`, `httputil.ParseHostHeader`, `replay.GetOrCreateSession`, `replay.PollForEntry`, `replay.ResetDefaultSession`.

- [ ] **Step 4: Update format.go**

Remove local `parsedHTTP` and `parseRawBase64`. Use `httputil.ParseBase64` + `httputil.ParsedMessage`.
Update `fmtResp` and `fmtReq` to work with `httputil.Header` (access `.Name`/`.Value` instead of `[0]`/`[1]`).

- [ ] **Step 5: Update request.go**

Use shared format functions.

- [ ] **Step 6: Verify build**

Run: `go build ./cmd/cli`

- [ ] **Step 7: Commit**

```
git commit -m "refactor: CLI uses shared httputil, replay, and auth packages"
```

---

### Task 7: Version injection + build scripts

**Files:**
- Modify: `cmd/mcp/root.go:10` - change `const version` to `var version`
- Modify: `scripts/build.sh` - add ldflags version injection, update build paths

- [ ] **Step 1: Update root.go**

```go
var version = "dev"
```

- [ ] **Step 2: Update build.sh**

```bash
# MCP server
GOOS="$GOOS" GOARCH="$GOARCH" CGO_ENABLED=0 \
  go build -C "$ROOT" \
  -ldflags="-s -w -X main.version=${VERSION}" \
  -o "${DIST}/caido-mcp-server-${suffix}" ./cmd/mcp

# CLI
GOOS="$GOOS" GOARCH="$GOARCH" CGO_ENABLED=0 \
  go build -C "$ROOT" \
  -ldflags="-s -w" \
  -o "${DIST}/caido-cli-${suffix}" ./cmd/cli
```

- [ ] **Step 3: Verify**

Run: `go build -ldflags="-X main.version=v1.2.0" -o /dev/null ./cmd/mcp`

- [ ] **Step 4: Commit**

```
git commit -m "fix: version injection via ldflags, update build paths"
```

---

### Task 8: Fix default mismatches + README

**Files:**
- Modify: `internal/tools/list_requests.go:44` - change default from 10 to 20
- Modify: `internal/tools/list_findings.go:49` - change default from 10 to 50

- [ ] **Step 1: Fix list_requests default**

Line 44: change `limit = 10` to `limit = 20`

- [ ] **Step 2: Fix list_findings default**

Line 49: change `limit = 10` to `limit = 50`

- [ ] **Step 3: Verify build**

Run: `go build ./cmd/mcp`

- [ ] **Step 4: Commit**

```
git commit -m "fix: align default limits with README (requests=20, findings=50)"
```

---

### Task 9: Final verification

- [ ] **Step 1: Build both binaries**

```bash
go build ./cmd/mcp && go build ./cmd/cli
```

- [ ] **Step 2: Run all tests**

```bash
go test ./... -v
```

- [ ] **Step 3: Run go vet**

```bash
go vet ./...
```

- [ ] **Step 4: Verify no duplicated code remains**

Check that `Caido-CLI/` directory is gone. Check that `internal/tools/http_utils.go` is gone. Grep for any remaining `map[string]string` header types in tool output structs.

- [ ] **Step 5: Final commit if any cleanup needed**
