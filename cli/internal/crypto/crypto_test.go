package crypto

import (
	"encoding/hex"
	"encoding/json"
	"os"
	"testing"
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

	kv := int(v["value"]["keyVersion"].(float64))
	plain, err := DecryptValue(b("value", "key"), s("value", "envId"), kv, s("value", "name"), s("value", "ciphertext"))
	if err != nil || plain != s("value", "plain") {
		t.Error("value", err)
	}
	if _, err := DecryptValue(b("value", "key"), s("value", "envId"), kv, "OTHER", s("value", "ciphertext")); err == nil {
		t.Error("value aad must bind name")
	}

	if B64(PasswordKey(s("password", "password"), b("password", "salt"))) != s("password", "key") {
		t.Error("password")
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
