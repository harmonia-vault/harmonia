// Package update 检查并下载新版本。发布源是 GitHub Releases 上带 minisign 签名的 manifest.json，
// 与用户自己部署的服务器无关。
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

const defaultManifestURL = "https://github.com/harmonia-vault/harmonia/releases/latest/download/manifest.json"

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

func manifestURL() string {
	if u := os.Getenv("HARMONIA_UPDATE_URL"); u != "" {
		return u
	}
	return defaultManifestURL
}

var client = &http.Client{Timeout: 60 * time.Second}

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

// Fetch 下载并验证发布清单。
func Fetch(ctx context.Context) (*Manifest, error) {
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
	url := manifestURL()
	data, err := get(ctx, url, 1<<20)
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
	return &m, nil
}

// Newer 判断版本 a 是否比 b 新（只比较 x.y.z 数字部分）。
func Newer(a, b string) bool {
	pa, pb := parse(a), parse(b)
	for i := 0; i < 3; i++ {
		if pa[i] != pb[i] {
			return pa[i] > pb[i]
		}
	}
	return false
}

func parse(v string) [3]int {
	var out [3]int
	v = strings.TrimPrefix(v, "v")
	v, _, _ = strings.Cut(v, "-")
	for i, p := range strings.SplitN(v, ".", 3) {
		out[i], _ = strconv.Atoi(p)
	}
	return out
}

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
