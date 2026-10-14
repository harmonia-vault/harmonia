package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
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
