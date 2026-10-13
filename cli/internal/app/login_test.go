package app

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type silentPrompt struct{}

func (silentPrompt) ShowPairing(string, string, string, time.Time, bool) {}
func (silentPrompt) Waiting()                                            {}

// fakeServer 模拟实例信息、匿名查询账号和发起配对（docs/protocol.md 3.2）。
func fakeServer(t *testing.T, lookup func(email string) (int, string), pairing func(r *http.Request, body map[string]any)) string {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/instance":
			w.Write([]byte(`{"product":"harmonia","version":"0.0.0","protocol":1,"registration":{"open":true}}`))
		case "/api/v1/accounts/lookup":
			status, body := lookup(r.URL.Query().Get("email"))
			w.WriteHeader(status)
			w.Write([]byte(body))
		case "/api/v1/pairings":
			var body map[string]any
			json.NewDecoder(r.Body).Decode(&body)
			pairing(r, body)
			w.WriteHeader(http.StatusUnauthorized)
			w.Write([]byte(`{"error":"unauthorized","message":"配对码不对或已过期。"}`))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	return srv.URL
}

func TestLoginRejectsUnknownOrUnfinishedAccount(t *testing.T) {
	t.Setenv("HARMONIA_HOME", t.TempDir())
	url := fakeServer(t, func(email string) (int, string) {
		if email == "half@example.com" {
			return 200, `{"accountId":"AAAAAAAAAAAAAAAAAAAAAA","initialized":false}`
		}
		return 404, `{"error":"not_found","message":"这个邮箱还没有注册。"}`
	}, func(*http.Request, map[string]any) { t.Error("不应发起配对") })

	_, _, err := Login(context.Background(), LoginInput{Server: url, Email: "nobody@example.com"}, silentPrompt{})
	if err == nil || !strings.Contains(err.Error(), "还没有注册") {
		t.Fatalf("未注册的邮箱：%v", err)
	}
	_, _, err = Login(context.Background(), LoginInput{Server: url, Email: " HALF@example.com "}, silentPrompt{})
	if err == nil || !strings.Contains(err.Error(), "还没有在手机上完成设置") {
		t.Fatalf("未初始化的账号：%v", err)
	}
}

func TestLoginSendsPairingCodeWithoutSession(t *testing.T) {
	t.Setenv("HARMONIA_HOME", t.TempDir())
	const accountID = "BBBBBBBBBBBBBBBBBBBBBB"
	const rootPub = "vfFpTqMA4G--_XgEwUFjt9EYD9j0wMMERHreyFaaoY4"
	var got map[string]any
	var header http.Header
	url := fakeServer(t, func(string) (int, string) {
		return 200, `{"accountId":"` + accountID + `","initialized":true,"rootPub":"` + rootPub + `"}`
	}, func(r *http.Request, body map[string]any) {
		got, header = body, r.Header
	})

	_, _, err := Login(context.Background(), LoginInput{Server: url, Email: "me@example.com", PairingCode: " ABCD-EFGH "}, silentPrompt{})
	if err == nil || !strings.Contains(err.Error(), "配对码不对") {
		t.Fatalf("应当返回服务端的提示：%v", err)
	}
	if got["code"] != "ABCD-EFGH" || got["rootPub"] != rootPub || got["canManage"] != false {
		t.Fatalf("配对请求内容不对：%v", got)
	}
	if header.Get("x-harmonia-account") != accountID || header.Get("authorization") != "" {
		t.Fatalf("应当只带账号请求头，不带会话：%v", header)
	}

	_, _, _ = Login(context.Background(), LoginInput{Server: url, Email: "me@example.com"}, silentPrompt{})
	if _, ok := got["code"]; ok {
		t.Fatalf("配对码留空时不应带 code：%v", got)
	}
}
