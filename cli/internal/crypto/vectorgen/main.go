// vectorgen 生成三端共用的测试向量：vectors/crypto.json。
// 固定输入保证派生类向量稳定；带随机 nonce 的密文只用于验证“对端能解开”。
package main

import (
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"

	"aead.dev/minisign"

	hc "github.com/harmonia-vault/harmonia/cli/internal/crypto"
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
	salt := seed(5)[:16]

	canonicalIn := []string{"harmonia.device", "AAAAAAAAAAAAAAAAAAAAAA", "client", "pub-a", "pub-b"}
	msg := hc.DeviceCertMsg("AAAAAAAAAAAAAAAAAAAAAA", "manager", hc.B64(sign.Pub), hc.B64(boxKey.Pub[:]))
	sealed := must(hc.Seal([]byte("environment-key-0123456789abcdef"), boxKey.Pub[:]))
	value := must(hc.EncryptValue(envKey, "BBBBBBBBBBBBBBBBBBBBBB", 1, "OPENAI_API_KEY", "sk-测试 value with 'quote'"))
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
		"value": map[string]any{
			"key": hc.B64(envKey), "envId": "BBBBBBBBBBBBBBBBBBBBBB", "keyVersion": 1,
			"name": "OPENAI_API_KEY", "ciphertext": value, "plain": "sk-测试 value with 'quote'",
		},
		"password": map[string]any{
			"password": "correct horse 电池", "salt": hc.B64(salt),
			"key": hc.B64(hc.PasswordKey("correct horse 电池", salt)),
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
}
