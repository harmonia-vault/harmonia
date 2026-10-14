package crypto

import (
	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/chacha20poly1305"
)

// ---- 本机密钥保护（docs/protocol.md 2.5，电脑上的管理身份）----

// PassphraseKey 按“口令派生”由管理口令得到 32 字节密钥：Argon2id，ops=3，mem=256 MiB，并行度 1。
func PassphraseKey(passphrase string, salt []byte) []byte {
	return argon2.IDKey([]byte(passphrase), salt, 3, 256*1024, 1, 32)
}

// SealLocal 用 XChaCha20-Poly1305 加密本机数据，返回 b64(nonce ‖ ciphertext ‖ tag)；AAD 是 aad 的规范数组。
func SealLocal(key, plain []byte, aad ...string) (string, error) {
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return "", err
	}
	nonce := Random(chacha20poly1305.NonceSizeX)
	return B64(aead.Seal(nonce, nonce, plain, Canonical(aad...))), nil
}

func OpenLocal(key []byte, sealed string, aad ...string) ([]byte, error) {
	raw, err := UnB64(sealed)
	if err != nil || len(raw) < chacha20poly1305.NonceSizeX+chacha20poly1305.Overhead {
		return nil, ErrDecrypt
	}
	aead, err := chacha20poly1305.NewX(key)
	if err != nil {
		return nil, err
	}
	n := chacha20poly1305.NonceSizeX
	plain, err := aead.Open(nil, raw[:n], raw[n:], Canonical(aad...))
	if err != nil {
		return nil, ErrDecrypt
	}
	return plain, nil
}
