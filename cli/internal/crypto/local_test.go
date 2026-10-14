package crypto

import (
	"bytes"
	"encoding/hex"
	"testing"
)

// 口令派生的结果用 OpenSSL 独立算出：
//
//	openssl kdf -keylen 32 -kdfopt pass:"Hqzv-mtkw 7" -kdfopt hexsalt:000102030405060708090a0b0c0d0e0f \
//	  -kdfopt iter:3 -kdfopt memcost:262144 -kdfopt lanes:1 ARGON2ID
func TestPassphraseKey(t *testing.T) {
	salt, _ := hex.DecodeString("000102030405060708090a0b0c0d0e0f")
	got := hex.EncodeToString(PassphraseKey("Hqzv-mtkw 7", salt))
	if want := "23e0bef16a120ff29d64d34fc1534873e6ea0b794f58f56023dc0ee30689d398"; got != want {
		t.Fatalf("口令派生结果不对：%s", got)
	}
}

func TestLocalSeal(t *testing.T) {
	key, plain := Random(32), []byte("本机数据")
	sealed, err := SealLocal(key, plain, "harmonia.local-slot", "passphrase")
	if err != nil {
		t.Fatal(err)
	}
	got, err := OpenLocal(key, sealed, "harmonia.local-slot", "passphrase")
	if err != nil || !bytes.Equal(got, plain) {
		t.Fatalf("解不开：%v", err)
	}
	if _, err := OpenLocal(key, sealed, "harmonia.local", "manager"); err != ErrDecrypt {
		t.Error("用途不同的密文不应能解开")
	}
	if _, err := OpenLocal(Random(32), sealed, "harmonia.local-slot", "passphrase"); err != ErrDecrypt {
		t.Error("密钥不对时不应能解开")
	}
	if _, err := OpenLocal(key, "AAAA", "harmonia.local-slot", "passphrase"); err != ErrDecrypt {
		t.Error("过短的密文应当报错")
	}
}
