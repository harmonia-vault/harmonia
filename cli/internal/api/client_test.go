package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestRequestsCarryClientVersion(t *testing.T) {
	var got []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.Header.Get("x-harmonia-version"))
		w.Write([]byte(`{}`))
	}))
	defer srv.Close()
	defer func(old string) { Version = old }(Version)

	c := New(srv.URL)
	for _, v := range []string{"0.3.1-rc.13", ""} {
		Version = v
		if err := c.do(context.Background(), "GET", "/api/v1/sync?since=0", nil, nil, reqOpts{}); err != nil {
			t.Fatal(err)
		}
	}
	if len(got) != 2 || got[0] != "0.3.1-rc.13" || got[1] != "" {
		t.Fatalf("上报的版本不对：%q", got)
	}
}

type fakeSigner struct{}

func (fakeSigner) DeviceID() string             { return "dev" }
func (fakeSigner) SignAuth(nonce string) string { return "sig" }

// 写请求遇到 5xx、限流时用同一个幂等键重试；其他错误不重试。
func TestDeviceWriteRetriesWithSameKey(t *testing.T) {
	defer func(old time.Duration) { retryWindow = old }(retryWindow)
	retryWindow = 5 * time.Second
	var keys []string
	fail := []int{500, 429}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/api/v1/auth/challenge":
			w.Write([]byte(`{"nonce":"n"}`))
			return
		case "/api/v1/auth/device-session":
			w.Write([]byte(`{"token":"t","expiresAt":4102444800000}`))
			return
		}
		keys = append(keys, r.Header.Get("idempotency-key"))
		if len(fail) > 0 {
			status := fail[0]
			fail = fail[1:]
			code := "internal"
			if status == 429 {
				code = "rate_limited"
				w.Header().Set("retry-after", "0")
			}
			w.WriteHeader(status)
			w.Write([]byte(`{"error":"` + code + `","message":"x"}`))
			return
		}
		w.Write([]byte(`{"seq":1}`))
	}))
	defer srv.Close()
	c := New(srv.URL)
	c.Signer = fakeSigner{}
	if err := c.PatchVariables(context.Background(), "env", "1", []VarWrite{{Name: "A", Value: "x"}}, nil, "key-12345678"); err != nil {
		t.Fatal(err)
	}
	if len(keys) != 3 || keys[0] != "key-12345678" || keys[2] != keys[0] {
		t.Fatalf("重试的幂等键不对：%q", keys)
	}

	keys = nil
	fail = []int{403}
	if err := c.PatchVariables(context.Background(), "env", "1", nil, []string{"A"}, "key-87654321"); err == nil || len(keys) != 1 {
		t.Fatalf("权限错误不应重试：%v %d", err, len(keys))
	}
}

func TestNetErrorReason(t *testing.T) {
	c := New("http://127.0.0.1:1")
	err := c.Public(context.Background(), "GET", "/api/v1/instance", nil, nil)
	if !IsNetwork(err) || !strings.Contains(err.Error(), "连接被拒绝") {
		t.Fatalf("错误说明不对：%v", err)
	}
}
