// Package update 检查并下载新版本。发布源是 GitHub Releases 上固定的 update-feed 发布中，
// 两份带 minisign 签名的清单：stable.json（正式版）与 beta.json（测试版，含正式版中较新的）。
// 更新源与用户自己部署的服务器无关。
package update

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	"aead.dev/minisign"
)

// ReleasePublicKey 是发布签名公钥（minisign 格式），由发布流程使用的私钥对应。
const ReleasePublicKey = "RWSG3mCrOrJkGKAhsnHOVBP4a+qs9VJi/47Vv3BQobIJ/ZamvbuQjabm"

// FeedBase 是更新源地址前缀。
const FeedBase = "https://github.com/harmonia-vault/harmonia/releases/download/update-feed"

// Channel 是更新渠道。
type Channel string

const (
	Stable Channel = "stable"
	Beta   Channel = "beta"
)

func ParseChannel(s string) (Channel, error) {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "stable", "正式版", "":
		return Stable, nil
	case "beta", "测试版":
		return Beta, nil
	}
	return "", fmt.Errorf("更新渠道只能是 stable（正式版）或 beta（测试版）")
}

func (c Channel) Label() string {
	if c == Beta {
		return "测试版"
	}
	return "正式版"
}

type Asset struct {
	URL    string `json:"url"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

type Manifest struct {
	Version  string           `json:"version"`
	Protocol int              `json:"protocol"`
	Notes    string           `json:"notes"`
	Assets   map[string]Asset `json:"assets"`
}

func manifestURL(ch Channel) string {
	if u := os.Getenv("HARMONIA_UPDATE_URL"); u != "" {
		return u
	}
	return FeedBase + "/" + string(ch) + ".json"
}

var client = &http.Client{Timeout: 60 * time.Second}

var errNotFound = errors.New("not found")

func get(ctx context.Context, url string, max int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return nil, err
	}
	res, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("无法连接更新服务器：%w", err)
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusNotFound {
		return nil, errNotFound
	}
	if res.StatusCode != 200 {
		return nil, fmt.Errorf("更新服务器返回 HTTP %d", res.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(res.Body, max+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > max {
		return nil, errors.New("下载内容超过预期大小")
	}
	return data, nil
}

// Fetch 下载并验证指定渠道的发布清单。
func Fetch(ctx context.Context, ch Channel) (*Manifest, error) {
	pubText := os.Getenv("HARMONIA_UPDATE_PUBKEY")
	if pubText == "" {
		pubText = ReleasePublicKey
	}
	if pubText == "" {
		return nil, errors.New("这个版本没有配置更新源（开发版本）")
	}
	var pub minisign.PublicKey
	if err := pub.UnmarshalText([]byte(pubText)); err != nil {
		return nil, errors.New("内置的发布公钥无效")
	}
	url := manifestURL(ch)
	data, err := get(ctx, url, 1<<20)
	if errors.Is(err, errNotFound) {
		return nil, fmt.Errorf("%s渠道还没有发布过版本", ch.Label())
	}
	if err != nil {
		return nil, err
	}
	sig, err := get(ctx, url+".minisig", 4096)
	if err != nil {
		return nil, err
	}
	if !minisign.Verify(pub, data, sig) {
		return nil, errors.New("更新清单的签名无效，已拒绝。请稍后重试或手动下载")
	}
	var m Manifest
	if err := json.Unmarshal(data, &m); err != nil || m.Version == "" {
		return nil, errors.New("更新清单格式不对")
	}
	// 正式版渠道只接受正式版本，防止测试版清单被当作正式版下发。
	if ch == Stable && IsPrerelease(m.Version) {
		return nil, errors.New("正式版更新源返回了测试版本，已拒绝")
	}
	return &m, nil
}

// 预发布标识的先后：rc 晚于 beta，beta 晚于 alpha；正式版晚于同一基础版本的全部预发布版本。
var preRank = map[string]int{"alpha": 1, "beta": 2, "rc": 3}

type version struct {
	base [3]int
	rank int // 正式版为 4
	num  int
}

func parse(v string) version {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	main, pre, hasPre := strings.Cut(v, "-")
	var out version
	for i, p := range strings.SplitN(main, ".", 3) {
		out.base[i], _ = strconv.Atoi(p)
	}
	if !hasPre {
		out.rank = 4
		return out
	}
	kind := strings.TrimRight(strings.ToLower(pre), "0123456789.")
	out.rank = preRank[kind]
	digits := strings.TrimLeft(pre[len(kind):], ".")
	out.num, _ = strconv.Atoi(digits)
	return out
}

// Compare 比较两个版本号：a 较新返回 1，较旧返回 -1，相同返回 0。
// 顺序示例：0.1.2 > 0.1.2-rc.2 > 0.1.2-rc.1 > 0.1.2-beta.3 > 0.1.1。
func Compare(a, b string) int {
	pa, pb := parse(a), parse(b)
	for _, d := range [][2]int{
		{pa.base[0], pb.base[0]}, {pa.base[1], pb.base[1]}, {pa.base[2], pb.base[2]},
		{pa.rank, pb.rank}, {pa.num, pb.num},
	} {
		if d[0] != d[1] {
			if d[0] > d[1] {
				return 1
			}
			return -1
		}
	}
	return 0
}

// Newer 判断版本 a 是否比 b 新。
func Newer(a, b string) bool { return Compare(a, b) > 0 }

// IsPrerelease 判断是否是测试版本（带 -rc.x、-beta.x 等后缀）。
func IsPrerelease(v string) bool { return strings.Contains(v, "-") }

// Download 下载资源并校验大小与 SHA-256。
func Download(ctx context.Context, a Asset) ([]byte, error) {
	data, err := get(ctx, a.URL, a.Size)
	if err != nil {
		return nil, err
	}
	sum := sha256.Sum256(data)
	if int64(len(data)) != a.Size || hex.EncodeToString(sum[:]) != a.SHA256 {
		return nil, errors.New("下载的文件校验失败，已放弃升级")
	}
	return data, nil
}
