package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"aead.dev/minisign"
)

func TestManifestAndroidSplitPackages(t *testing.T) {
	dir := t.TempDir()
	pub, key, err := minisign.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	text, err := key.MarshalText()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("HARMONIA_RELEASE_KEY", string(text))
	for _, name := range []string{
		"harmonia-darwin-arm64", "harmonia-darwin-amd64", "harmonia-linux-arm64", "harmonia-linux-amd64",
		"harmonia-windows-arm64.exe", "harmonia-windows-amd64.exe", "harmonia-0.3.1-rc.10.ipa",
		"harmonia-0.3.1-rc.10-android-arm64.apk", "harmonia-0.3.1-rc.10-android-arm.apk",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(name), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := manifest([]string{"--version", "0.3.1-rc.10", "--dist", dir, "--base-url", "https://example.invalid/release"}); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filepath.Join(dir, "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	sig, err := os.ReadFile(filepath.Join(dir, "manifest.json.minisig"))
	if err != nil || !minisign.Verify(pub, data, sig) {
		t.Fatalf("签名清单校验失败：%v", err)
	}
	var result struct{ Assets map[string]asset }
	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatal(err)
	}
	if len(result.Assets) != 9 || result.Assets["android"].URL != "" {
		t.Fatalf("发布物数量或资源键错误：%v", result.Assets)
	}
	for _, arch := range []string{"arm64", "arm"} {
		name := "harmonia-0.3.1-rc.10-android-" + arch + ".apk"
		sum := sha256.Sum256([]byte(name))
		want := asset{URL: "https://example.invalid/release/" + name, SHA256: hex.EncodeToString(sum[:]), Size: int64(len(name))}
		if got := result.Assets["android-"+arch]; got != want {
			t.Fatalf("%s 安装包清单错误：%+v", arch, got)
		}
	}
}
