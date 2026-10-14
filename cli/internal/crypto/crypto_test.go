package crypto

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"

	"golang.org/x/crypto/chacha20poly1305"
)

// 校验 vectors/crypto.json：保证 Go 与 Dart/TS 的结果一致。
func TestVectors(t *testing.T) {
	raw, err := os.ReadFile("../../../vectors/crypto.json")
	if err != nil {
		t.Fatal(err)
	}
	var v map[string]map[string]any
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatal(err)
	}
	s := func(sec, key string) string { return v[sec][key].(string) }
	b := func(sec, key string) []byte {
		out, err := UnB64(s(sec, key))
		if err != nil {
			t.Fatal(sec, key, err)
		}
		return out
	}

	var items []string
	for _, it := range v["canonical"]["items"].([]any) {
		items = append(items, it.(string))
	}
	if hex.EncodeToString(Canonical(items...)) != s("canonical", "hex") {
		t.Error("canonical")
	}

	sk := SignKeyFromSeed(b("sign", "seed"))
	msg, _ := hex.DecodeString(s("sign", "msgHex"))
	if B64(sk.Pub) != s("sign", "pub") || B64(sk.Sign(msg)) != s("sign", "sig") {
		t.Error("sign")
	}
	if !Verify(sk.Pub, msg, b("sign", "sig")) || Verify(sk.Pub, append(msg, 'x'), b("sign", "sig")) {
		t.Error("verify")
	}

	bk := BoxKeyFromSeed(b("box", "seed"))
	if B64(bk.Pub[:]) != s("box", "pub") {
		t.Error("box pub")
	}
	if plain, err := bk.Open(b("box", "sealed")); err != nil || string(plain) != s("box", "plain") {
		t.Error("box open", err)
	}

	kv := int(v["var"]["keyVersion"].(float64))
	e, err := DecryptVar(b("var", "key"), s("var", "envId"), kv, s("var", "name"), s("var", "ciphertext"))
	if err != nil || e.Value != s("var", "value") || e.Note != s("var", "note") {
		t.Error("var", err)
	}
	if e, err := DecryptVar(b("var", "key"), s("var", "envId"), kv, s("var", "noNoteName"), s("var", "noNoteCiphertext")); err != nil || e != (Entry{Value: "v"}) {
		t.Error("var without note", err)
	}
	if _, err := DecryptVar(b("var", "key"), s("var", "envId"), kv, "OTHER", s("var", "ciphertext")); err == nil {
		t.Error("var aad must bind name")
	}

	code := b("recovery", "code")
	if FormatRecoveryCode(code) != s("recovery", "formatted") {
		t.Error("recovery format")
	}
	parsed, err := ParseRecoveryCode(" " + s("recovery", "formatted") + "\n")
	if err != nil || B64(parsed) != s("recovery", "code") {
		t.Error("recovery parse", err)
	}
	rk := DeriveRecovery(code)
	if B64(rk.Sign.Pub) != s("recovery", "signPub") || B64(rk.Box.Pub[:]) != s("recovery", "boxPub") {
		t.Error("recovery derive")
	}

	fp := PairingFingerprint(s("pairing", "pairingId"), s("pairing", "signPub"), s("pairing", "boxPub"), s("pairing", "rootPub"))
	if B64(fp) != s("pairing", "fingerprint") || PairingCode(fp) != s("pairing", "code") ||
		PairingQR(s("pairing", "pairingId"), fp) != s("pairing", "qr") {
		t.Error("pairing")
	}

	if hex.EncodeToString(EnvelopeMsg("BBBBBBBBBBBBBBBBBBBBBB", 1, "recovery", []byte("sealed"))) != s("messages", "envelope") ||
		hex.EncodeToString(RootRecoveryMsg(2, []byte("sealed"))) != s("messages", "rootRecovery") ||
		hex.EncodeToString(AuthMsg("AAAAAAAAAAAAAAAAAAAAAA", "nonce-1")) != s("messages", "auth") ||
		hex.EncodeToString(RecoveryAuthMsg("nonce-2")) != s("messages", "recoveryAuth") {
		t.Error("messages")
	}
}

func TestSealRoundTrip(t *testing.T) {
	k := BoxKeyFromSeed(Random(32))
	sealed, err := Seal([]byte("hello"), k.Pub[:])
	if err != nil {
		t.Fatal(err)
	}
	if out, err := k.Open(sealed); err != nil || string(out) != "hello" {
		t.Fatal("round trip")
	}
	other := BoxKeyFromSeed(Random(32))
	if _, err := other.Open(sealed); err == nil {
		t.Fatal("wrong key must fail")
	}
}

func TestVarRoundTripKeepsUnknownFields(t *testing.T) {
	key := Random(32)
	ct, err := EncryptVar(key, "E", 1, "N", Entry{Value: "a\nb<&>", Note: "只有备注"})
	if err != nil {
		t.Fatal(err)
	}
	if e, err := DecryptVar(key, "E", 1, "N", ct); err != nil || e.Value != "a\nb<&>" || e.Note != "只有备注" {
		t.Fatal("round trip", e, err)
	}
	seal := func(plain string) string {
		aead, _ := chacha20poly1305.NewX(key)
		nonce := Random(chacha20poly1305.NonceSizeX)
		return B64(aead.Seal(nonce, nonce, []byte(plain), varAAD("E", 1, "N")))
	}
	// 新版本加入的字段：读取时忽略，改写备注后仍然保留。
	e, err := DecryptVar(key, "E", 1, "N", seal(`{"value":"v","note":"旧","tags":["x"]}`))
	if err != nil || e.Value != "v" || e.Note != "旧" {
		t.Fatal("unknown field", e, err)
	}
	e.Note = ""
	ct, _ = EncryptVar(key, "E", 1, "N", e)
	plain, _ := openVar(key, ct, varAAD("E", 1, "N"))
	if string(plain) != `{"tags":["x"],"value":"v"}` {
		t.Fatal("rewrite", string(plain))
	}
	for _, bad := range []string{`"v"`, `{}`, `{"value":1}`, `{"value":"v","note":2}`, `null`, `not json`} {
		if _, err := DecryptVar(key, "E", 1, "N", seal(bad)); err == nil {
			t.Error("must reject", bad)
		}
	}
}
