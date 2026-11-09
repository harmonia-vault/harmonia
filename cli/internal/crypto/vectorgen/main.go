// vectorgen 生成三端共用的测试向量：vectors/crypto.json，以及环境展开规则的 vectors/refs.json。
// 固定输入保证派生类向量稳定；带随机 nonce 的密文只用于验证“对端能解开”。
package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"aead.dev/minisign"

	"github.com/harmonia-vault/harmonia/cli/internal/api"
	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
	"github.com/harmonia-vault/harmonia/cli/internal/refs"
)

func seed(b byte) []byte {
	s := make([]byte, 32)
	for i := range s {
		s[i] = b + byte(i)
	}
	return s
}

func must[T any](v T, err error) T {
	if err != nil {
		panic(err)
	}
	return v
}

func main() {
	out := "vectors"
	if len(os.Args) > 1 {
		out = os.Args[1]
	}
	sign := hc.SignKeyFromSeed(seed(1))
	boxKey := hc.BoxKeyFromSeed(seed(2))
	envKey := seed(3)
	code := seed(4)[:16]
	rec := hc.DeriveRecovery(code)

	canonicalIn := []string{"harmonia.device", "AAAAAAAAAAAAAAAAAAAAAA", "client", "pub-a", "pub-b"}
	msg := hc.DeviceCertMsg("AAAAAAAAAAAAAAAAAAAAAA", "manager", hc.B64(sign.Pub), hc.B64(boxKey.Pub[:]))
	sealed := must(hc.Seal([]byte("environment-key-0123456789abcdef"), boxKey.Pub[:]))
	entry := hc.Entry{Value: "sk-测试 value with 'quote'", Note: "测试用的 Key\n第二行"}
	varCT := must(hc.EncryptVar(envKey, "BBBBBBBBBBBBBBBBBBBBBB", 1, "OPENAI_API_KEY", entry))
	noNoteCT := must(hc.EncryptVar(envKey, "BBBBBBBBBBBBBBBBBBBBBB", 1, "EMPTY_NOTE", hc.Entry{Value: "v"}))
	fp := hc.PairingFingerprint("CCCCCCCCCCCCCCCCCCCCCC", hc.B64(sign.Pub), hc.B64(boxKey.Pub[:]), hc.B64(rec.Sign.Pub))

	v := map[string]any{
		"canonical": map[string]any{"items": canonicalIn, "hex": hex.EncodeToString(hc.Canonical(canonicalIn...))},
		"sign": map[string]any{
			"seed": hc.B64(sign.Seed), "pub": hc.B64(sign.Pub),
			"msgHex": hex.EncodeToString(msg), "sig": hc.B64(sign.Sign(msg)),
		},
		"box": map[string]any{
			"seed": hc.B64(boxKey.Seed), "pub": hc.B64(boxKey.Pub[:]),
			"sealed": hc.B64(sealed), "plain": "environment-key-0123456789abcdef",
		},
		"var": map[string]any{
			"key": hc.B64(envKey), "envId": "BBBBBBBBBBBBBBBBBBBBBB", "keyVersion": 1,
			"name": "OPENAI_API_KEY", "ciphertext": varCT, "value": entry.Value, "note": entry.Note,
			"noNoteName": "EMPTY_NOTE", "noNoteCiphertext": noNoteCT,
		},
		"recovery": map[string]any{
			"code": hc.B64(code), "formatted": hc.FormatRecoveryCode(code),
			"signPub": hc.B64(rec.Sign.Pub), "boxPub": hc.B64(rec.Box.Pub[:]),
		},
		"pairing": map[string]any{
			"pairingId": "CCCCCCCCCCCCCCCCCCCCCC", "signPub": hc.B64(sign.Pub),
			"boxPub": hc.B64(boxKey.Pub[:]), "rootPub": hc.B64(rec.Sign.Pub),
			"fingerprint": hc.B64(fp), "code": hc.PairingCode(fp), "qr": hc.PairingQR("CCCCCCCCCCCCCCCCCCCCCC", fp),
		},
		"messages": map[string]any{
			"envelope":     hex.EncodeToString(hc.EnvelopeMsg("BBBBBBBBBBBBBBBBBBBBBB", 1, "recovery", []byte("sealed"))),
			"rootRecovery": hex.EncodeToString(hc.RootRecoveryMsg(2, []byte("sealed"))),
			"auth":         hex.EncodeToString(hc.AuthMsg("AAAAAAAAAAAAAAAAAAAAAA", "nonce-1")),
			"recoveryAuth": hex.EncodeToString(hc.RecoveryAuthMsg("nonce-2")),
		},
	}
	// minisign：使用临时测试密钥，验证 App 端的发布签名校验实现。
	mpub, mpriv, _ := minisign.GenerateKey(nil)
	mpubText, _ := mpub.MarshalText()
	mmsg := []byte(`{"version":"9.9.9"}`)
	v["minisign"] = map[string]any{
		"publicKey": string(mpubText), "message": string(mmsg),
		"signature": string(minisign.SignWithComments(mpriv, mmsg, "timestamp:0", "test")),
	}
	data := must(json.MarshalIndent(v, "", "  "))
	path := filepath.Join(out, "crypto.json")
	if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
		panic(err)
	}
	fmt.Println("已写入", path)
	writeRefs(out)
}

// writeRefs 生成环境展开规则的向量：给定引用和各变量库现存的变量名，期望的最终名字、被遮住的和重名。
func writeRefs(out string) {
	const a, b, gone = "AAAAAAAAAAAAAAAAAAAAAA", "BBBBBBBBBBBBBBBBBBBBBB", "GGGGGGGGGGGGGGGGGGGGGG"
	type tc struct {
		Name   string              `json:"name"`
		Refs   []api.Ref           `json:"refs"`
		Vaults map[string][]string `json:"vaults"`
	}
	cases := []tc{
		{"勾选只取存在的变量并保持勾选顺序，全部变量按名字排序并应用改名", []api.Ref{
			{VaultID: a, Scope: "pick", Items: []api.RefItem{{Name: "OPENAI_API_KEY", As: "LLM_KEY"}, {Name: "MISSING"}, {Name: "ANTHROPIC_KEY"}}},
			{VaultID: b, Scope: "all", Writable: true, Items: []api.RefItem{{Name: "Z", As: "ZED"}}},
		}, map[string][]string{a: {"OPENAI_API_KEY", "OTHER", "ANTHROPIC_KEY"}, b: {"Z", "DB_URL"}}},
		{"同名时排在前面的引用优先，其余被遮住", []api.Ref{
			{VaultID: a, Scope: "all"}, {VaultID: b, Scope: "all"},
		}, map[string][]string{a: {"K"}, b: {"K", "J"}}},
		{"勾选的变量不存在也参与重名检查", []api.Ref{
			{VaultID: a, Scope: "pick", Items: []api.RefItem{{Name: "X", As: "K"}}}, {VaultID: b, Scope: "all"},
		}, map[string][]string{a: {}, b: {"K", "J"}}},
		{"同一个变量库里改名撞上另一个变量", []api.Ref{
			{VaultID: a, Scope: "all", Items: []api.RefItem{{Name: "A", As: "B"}}},
		}, map[string][]string{a: {"A", "B", "C"}}},
		{"已删除的变量库不提供变量", []api.Ref{
			{VaultID: gone, Scope: "all"}, {VaultID: a, Scope: "pick", Writable: true, Items: []api.RefItem{{Name: "K"}}},
		}, map[string][]string{a: {"K", "L"}}},
	}
	var list []map[string]any
	for _, c := range cases {
		names := func(id string) []string { return c.Vaults[id] }
		for i := range c.Refs {
			if c.Refs[i].Items == nil {
				c.Refs[i].Items = []api.RefItem{}
			}
		}
		items, shadowed := refs.Expand(c.Refs, names)
		list = append(list, map[string]any{
			"name": c.Name, "refs": c.Refs, "vaults": c.Vaults,
			"items": items, "shadowed": shadowed, "duplicates": refs.Duplicates(c.Refs, names),
		})
	}
	data := must(json.MarshalIndent(map[string]any{"cases": list}, "", "  "))
	path := filepath.Join(out, "refs.json")
	if err := os.WriteFile(path, append(data, '\n'), 0o644); err != nil {
		panic(err)
	}
	fmt.Println("已写入", path)
}
