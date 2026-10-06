// releasetool 是发布流程使用的小工具：生成发布签名密钥、生成并签名 manifest.json。
//
//	releasetool keygen <输出目录>
//	releasetool manifest --version 0.1.0 --dist dist --base-url URL [--notes 文本]
//	（签名私钥从环境变量 HARMONIA_RELEASE_KEY 读取）
//	releasetool feed --version 0.1.0 --dist dist --feed feed
//	（把本次清单写入更新源：beta.json 取最新版本；正式版本同时更新 stable.json）
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"aead.dev/minisign"

	"github.com/harmonia-vault/harmonia/cli/internal/update"
)

type asset struct {
	URL    string `json:"url"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "用法：releasetool keygen <目录> | manifest ...")
		os.Exit(2)
	}
	var err error
	switch os.Args[1] {
	case "keygen":
		err = keygen(os.Args[2])
	case "manifest":
		err = manifest(os.Args[2:])
	case "feed":
		err = feed(os.Args[2:])
	default:
		err = fmt.Errorf("未知命令 %s", os.Args[1])
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "错误：", err)
		os.Exit(1)
	}
}

func keygen(dir string) error {
	pub, priv, err := minisign.GenerateKey(nil)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	pubText, _ := pub.MarshalText()
	privText, _ := priv.MarshalText()
	if err := os.WriteFile(filepath.Join(dir, "release.pub"), pubText, 0o644); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(dir, "release.key"), privText, 0o600); err != nil {
		return err
	}
	fmt.Printf("公钥：%s\n", pubText)
	return nil
}

func manifest(args []string) error {
	fs := flag.NewFlagSet("manifest", flag.ExitOnError)
	version := fs.String("version", "", "版本号")
	dist := fs.String("dist", "dist", "发布文件目录")
	base := fs.String("base-url", "", "下载地址前缀")
	notes := fs.String("notes", "", "更新说明")
	fs.Parse(args)
	var key minisign.PrivateKey
	if err := key.UnmarshalText([]byte(os.Getenv("HARMONIA_RELEASE_KEY"))); err != nil {
		return fmt.Errorf("HARMONIA_RELEASE_KEY 无效：%w", err)
	}
	files := map[string]string{
		"cli-darwin-arm64": "harmonia-darwin-arm64",
		"cli-darwin-amd64": "harmonia-darwin-amd64",
		"cli-linux-arm64":  "harmonia-linux-arm64",
		"cli-linux-amd64":  "harmonia-linux-amd64",
		"android":          "harmonia-" + *version + ".apk",
	}
	assets := map[string]asset{}
	for key, name := range files {
		data, err := os.ReadFile(filepath.Join(*dist, name))
		if err != nil {
			return err
		}
		sum := sha256.Sum256(data)
		assets[key] = asset{URL: *base + "/" + name, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(data))}
	}
	m := map[string]any{"version": *version, "protocol": 1, "notes": *notes, "assets": assets}
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(*dist, "manifest.json"), data, 0o644); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(*dist, "manifest.json.minisig"), minisign.Sign(key, data), 0o644)
}

// feed 只在本次版本比更新源中已有的版本新时才覆盖，避免补丁旧版本时把渠道回退。
func feed(args []string) error {
	fs := flag.NewFlagSet("feed", flag.ExitOnError)
	version := fs.String("version", "", "版本号")
	dist := fs.String("dist", "dist", "发布文件目录（含 manifest.json 与签名）")
	dir := fs.String("feed", "feed", "更新源目录（含现有的 stable.json / beta.json）")
	fs.Parse(args)
	manifest, err := os.ReadFile(filepath.Join(*dist, "manifest.json"))
	if err != nil {
		return err
	}
	sig, err := os.ReadFile(filepath.Join(*dist, "manifest.json.minisig"))
	if err != nil {
		return err
	}
	channels := []update.Channel{update.Beta}
	if !update.IsPrerelease(*version) {
		channels = append(channels, update.Stable)
	}
	for _, ch := range channels {
		path := filepath.Join(*dir, string(ch)+".json")
		if data, err := os.ReadFile(path); err == nil {
			var cur struct{ Version string }
			if json.Unmarshal(data, &cur) == nil && !update.Newer(*version, cur.Version) {
				fmt.Printf("%s 渠道已是 %s，不更新\n", ch, cur.Version)
				continue
			}
		}
		if err := os.WriteFile(path, manifest, 0o644); err != nil {
			return err
		}
		if err := os.WriteFile(path+".minisig", sig, 0o644); err != nil {
			return err
		}
		fmt.Printf("%s 渠道更新为 %s\n", ch, *version)
	}
	return nil
}
