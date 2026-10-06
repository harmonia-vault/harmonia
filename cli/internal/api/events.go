package api

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"
)

type Event struct {
	Type string `json:"type"`
	Seq  int64  `json:"seq"`
}

// Listen 保持一条推送连接，直到 ctx 结束或连接断开；每收到一条提示调用 onEvent。
func (c *Client) Listen(ctx context.Context, onEvent func(Event)) error {
	token, err := c.DeviceToken(ctx)
	if err != nil {
		return err
	}
	wsURL := "ws" + strings.TrimPrefix(c.Base, "http") + "/api/v1/events"
	h := http.Header{}
	h.Set("authorization", "Bearer "+token)
	conn, _, err := websocket.Dial(ctx, wsURL, &websocket.DialOptions{HTTPHeader: h, HTTPClient: c.HTTP})
	if err != nil {
		return err
	}
	defer conn.CloseNow()
	conn.SetReadLimit(64 << 10)
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				wctx, wcancel := context.WithTimeout(ctx, 10*time.Second)
				err := conn.Write(wctx, websocket.MessageText, []byte("ping"))
				wcancel()
				if err != nil {
					cancel()
					return
				}
			}
		}
	}()
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			if websocket.CloseStatus(err) == 4001 {
				return ErrRevoked
			}
			return err
		}
		if string(data) == "pong" {
			continue
		}
		var ev Event
		if json.Unmarshal(data, &ev) == nil {
			if ev.Type == "revoked" {
				return ErrRevoked
			}
			onEvent(ev)
		}
	}
}
