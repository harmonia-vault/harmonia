package update

import (
	"testing"
	"time"
)

func TestCacheAvailable(t *testing.T) {
	c := Cache{Channel: "stable", Latest: "0.10.0"}
	if got := c.Available(Stable, "0.9.0"); got != "0.10.0" {
		t.Errorf("有新版本时应返回它，得到 %q", got)
	}
	if got := c.Available(Stable, "0.10.0"); got != "" {
		t.Errorf("已是最新时应为空，得到 %q", got)
	}
	if got := c.Available(Beta, "0.9.0"); got != "" {
		t.Errorf("切换渠道后旧结果不算数，得到 %q", got)
	}
}

func TestCacheStale(t *testing.T) {
	now := time.Date(2026, 10, 14, 12, 0, 0, 0, time.Local)
	if !(Cache{}).Stale(Stable, now) {
		t.Error("从没检查过应当需要检查")
	}
	c := Cache{Channel: "stable", CheckedAt: now.Add(-23 * time.Hour).UnixMilli()}
	if c.Stale(Stable, now) {
		t.Error("23 小时前检查过，不需要再检查")
	}
	if !c.Stale(Beta, now) {
		t.Error("渠道切换后需要重新检查")
	}
	c.CheckedAt = now.Add(-25 * time.Hour).UnixMilli()
	if !c.Stale(Stable, now) {
		t.Error("超过 24 小时需要重新检查")
	}
}

func TestCacheShouldHint(t *testing.T) {
	now := time.Date(2026, 10, 14, 9, 0, 0, 0, time.Local)
	c := Cache{Channel: "stable", Latest: "0.10.0"}
	if !c.ShouldHint(Stable, "0.9.0", now) {
		t.Error("有新版本且没提示过，应当提示")
	}
	c.HintedAt = now.Add(-8 * time.Hour).UnixMilli() // 同一天凌晨 1 点
	if c.ShouldHint(Stable, "0.9.0", now) {
		t.Error("今天已经提示过，不再提示")
	}
	c.HintedAt = now.Add(-10 * time.Hour).UnixMilli() // 前一天晚上 11 点
	if !c.ShouldHint(Stable, "0.9.0", now) {
		t.Error("昨天提示过，今天应当再提示一次")
	}
	if c.ShouldHint(Stable, "0.10.0", now) {
		t.Error("已是最新版本时不提示")
	}
}
