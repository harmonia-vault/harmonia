package managerui

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"

	"github.com/harmonia-vault/harmonia/cli/internal/state"
)

type client struct {
	t    *testing.T
	base string
}

func start(t *testing.T) (*Server, *client) {
	t.Setenv("HARMONIA_HOME", t.TempDir())
	d, err := state.Open()
	if err != nil {
		t.Fatal(err)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	s := New(ctx, d, ln)
	go s.Serve(ln)
	return s, &client{t: t, base: "http://" + ln.Addr().String()}
}

// do 发一个请求，返回状态码和解析后的 JSON（不是 JSON 时为 nil）。
func (c *client) do(method, path, body string, headers map[string]string) (int, map[string]any, http.Header) {
	req, err := http.NewRequest(method, c.base+path, strings.NewReader(body))
	if err != nil {
		c.t.Fatal(err)
	}
	for k, v := range headers {
		if k == "Host" {
			req.Host = v
		} else {
			req.Header.Set(k, v)
		}
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		c.t.Fatal(err)
	}
	defer res.Body.Close()
	raw, _ := io.ReadAll(res.Body)
	var out map[string]any
	_ = json.Unmarshal(raw, &out)
	return res.StatusCode, out, res.Header
}

func TestAccessControl(t *testing.T) {
	s, c := start(t)
	js := map[string]string{"Content-Type": "application/json"}
	with := func(extra map[string]string) map[string]string {
		out := map[string]string{"Content-Type": "application/json"}
		for k, v := range extra {
			out[k] = v
		}
		return out
	}
	code := strings.SplitN(s.URL(), "#", 2)[1]

	if status, _, h := c.do("GET", "/", "", nil); status != 200 || !strings.Contains(h.Get("Content-Security-Policy"), "default-src 'none'") || h.Get("X-Frame-Options") != "DENY" {
		t.Fatalf("页面应当能打开并带上安全响应头：%d %v", status, h)
	}
	if status, _, _ := c.do("GET", "/", "", map[string]string{"Host": "evil.example"}); status != 403 {
		t.Errorf("Host 不是本机地址时应当拒绝：%d", status)
	}
	if status, _, _ := c.do("POST", "/api/session", `{"code":"`+code+`"}`, with(map[string]string{"Origin": "http://evil.example"})); status != 403 {
		t.Errorf("来自其他网站的请求应当拒绝：%d", status)
	}
	if status, _, _ := c.do("POST", "/api/session", `code=`+code, map[string]string{"Content-Type": "application/x-www-form-urlencoded"}); status != 415 {
		t.Errorf("不是 JSON 的请求应当拒绝：%d", status)
	}
	if status, _, _ := c.do("GET", "/api/state", "", nil); status != 401 {
		t.Errorf("没有令牌时接口应当拒绝：%d", status)
	}
	if status, _, _ := c.do("POST", "/api/session", `{"code":"wrong"}`, js); status != 403 {
		t.Errorf("访问码不对时应当拒绝：%d", status)
	}
	status, out, _ := c.do("POST", "/api/session", `{"code":"`+code+`"}`, js)
	token, _ := out["token"].(string)
	if status != 200 || token == "" {
		t.Fatalf("访问码应当能换到令牌：%d %v", status, out)
	}
	if status, _, _ := c.do("POST", "/api/session", `{"code":"`+code+`"}`, js); status != 403 {
		t.Errorf("访问码只能用一次：%d", status)
	}
	if strings.Contains(s.URL(), code) {
		t.Error("访问码用过之后不应还留着")
	}
	auth := with(map[string]string{"Authorization": "Bearer " + token})
	if status, out, _ := c.do("GET", "/api/state", "", auth); status != 200 || out["phase"] != "login" {
		t.Errorf("带令牌应当能读到状态：%d %v", status, out)
	}
	if status, _, _ := c.do("GET", "/api/state", "", with(map[string]string{"Authorization": "Bearer " + token + "x"})); status != 401 {
		t.Errorf("令牌不对时应当拒绝：%d", status)
	}
	// 没有解锁时，数据接口一律拒绝。
	if status, out, _ := c.do("POST", "/api/envs/list", `{}`, auth); status != 409 || out["error"] != "locked" {
		t.Errorf("没有解锁时不应能读取环境：%d %v", status, out)
	}
	if status, out, _ := c.do("POST", "/api/unlock", `{"passphrase":"whatever-1A"}`, auth); status != 400 || !strings.Contains(out["message"].(string), "还没有管理登录") {
		t.Errorf("没有管理登录时解锁应当说明原因：%d %v", status, out)
	}
	// 口令不合规时，管理登录在联网之前就被拒绝。
	if status, out, _ := c.do("POST", "/api/login", `{"server":"http://localhost:1","email":"a@example.com","deviceName":"x","passphrase":"password1"}`, auth); status != 400 || !strings.Contains(out["message"].(string), "太常见") {
		t.Errorf("常见口令应当被拒绝：%d %v", status, out)
	}
}
