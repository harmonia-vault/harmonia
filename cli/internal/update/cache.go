package update

import "time"

// CheckInterval 是两次检查之间的间隔（docs/rewrite-plan.md 5.11）。
const CheckInterval = 24 * time.Hour

// Cache 是本机记录的检查结果（数据目录中的 update.json），由后台服务或命令写入。
type Cache struct {
	Channel   string `json:"channel"`
	Latest    string `json:"latest"`
	CheckedAt int64  `json:"checkedAt"`
	// HintedAt 是上一次在命令输出后提示有新版本的时间，用来做到每天最多提示一次。
	HintedAt int64 `json:"hintedAt,omitempty"`
	// Failed 是后台服务上一次自动升级失败的原因，升级成功或再次检查时清除。
	Failed   string `json:"failed,omitempty"`
	FailedAt int64  `json:"failedAt,omitempty"`
}

// Available 返回比 current 新的版本；渠道已经切换过的结果不算数，没有时返回空。
func (c Cache) Available(ch Channel, current string) string {
	if c.Channel != string(ch) || !Newer(c.Latest, current) {
		return ""
	}
	return c.Latest
}

// Stale 表示需要重新检查：从没检查过、渠道已经切换，或者距上次检查超过一个间隔。
func (c Cache) Stale(ch Channel, now time.Time) bool {
	return c.Channel != string(ch) || now.Sub(time.UnixMilli(c.CheckedAt)) > CheckInterval
}

// ShouldHint 表示现在该提示有新版本：有新版本，并且今天（本地日期）还没有提示过。
func (c Cache) ShouldHint(ch Channel, current string, now time.Time) bool {
	if c.Available(ch, current) == "" {
		return false
	}
	last := time.UnixMilli(c.HintedAt).In(now.Location())
	y1, m1, d1 := last.Date()
	y2, m2, d2 := now.Date()
	return c.HintedAt == 0 || y1 != y2 || m1 != m2 || d1 != d2
}
