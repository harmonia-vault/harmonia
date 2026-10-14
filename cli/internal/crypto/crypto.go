// Package crypto 实现 docs/protocol.md 第 2 节定义的全部密码学构件。
package crypto

import (
	"bytes"
	"crypto/ed25519"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/base32"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strconv"
	"strings"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/nacl/box"
)

const MaxValueLen = 65536

var (
	ErrDecrypt   = errors.New("解密失败")
	ErrSignature = errors.New("签名无效")
	// Crockford Base32 字母表：不含 I、L、O、U，避免手抄时混淆。
	b32 = base32.NewEncoding("0123456789ABCDEFGHJKMNPQRSTVWXYZ").WithPadding(base32.NoPadding)
)

// B64 / UnB64 使用无填充 base64url。
func B64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func UnB64(s string) ([]byte, error) { return base64.RawURLEncoding.DecodeString(s) }

func Random(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return b
}

// NewID 返回 16 字节随机数的 b64（22 个字符）。
func NewID() string { return B64(Random(16)) }

// Canonical 返回规范数组字节：字符串数组的紧凑 JSON。
func Canonical(items ...string) []byte {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(items); err != nil {
		panic(err)
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte("\n"))
}

func SHA256(b []byte) []byte {
	h := sha256.Sum256(b)
	return h[:]
}

// HKDF 使用空 salt 输出 32 字节。
func HKDF(ikm []byte, info string) []byte {
	out, err := hkdf.Key(sha256.New, ikm, nil, info, 32)
	if err != nil {
		panic(err)
	}
	return out
}

// SignKey 是 Ed25519 签名密钥对。
type SignKey struct {
	Seed []byte
	Pub  ed25519.PublicKey
	priv ed25519.PrivateKey
}

func SignKeyFromSeed(seed []byte) SignKey {
	priv := ed25519.NewKeyFromSeed(seed)
	return SignKey{Seed: seed, Pub: priv.Public().(ed25519.PublicKey), priv: priv}
}

func (k SignKey) Sign(msg []byte) []byte { return ed25519.Sign(k.priv, msg) }

func Verify(pub, msg, sig []byte) bool {
	return len(pub) == ed25519.PublicKeySize && ed25519.Verify(pub, msg, sig)
}

// BoxKey 按 crypto_box_seed_keypair 由种子派生。
type BoxKey struct {
	Seed []byte
	Pub  [32]byte
	sk   [32]byte
}

func BoxKeyFromSeed(seed []byte) BoxKey {
	h := sha512.Sum512(seed)
	var k BoxKey
	k.Seed = seed
	copy(k.sk[:], h[:32])
	pub, err := curve25519.X25519(k.sk[:], curve25519.Basepoint)
	if err != nil {
		panic(err)
	}
	copy(k.Pub[:], pub)
	return k
}

// Seal 等价于 crypto_box_seal。
func Seal(msg []byte, recipientPub []byte) ([]byte, error) {
	if len(recipientPub) != 32 {
		return nil, errors.New("公钥长度错误")
	}
	var pk [32]byte
	copy(pk[:], recipientPub)
	return box.SealAnonymous(nil, msg, &pk, rand.Reader)
}

// Open 等价于 crypto_box_seal_open。
func (k BoxKey) Open(sealed []byte) ([]byte, error) {
	out, ok := box.OpenAnonymous(nil, sealed, &k.Pub, &k.sk)
	if !ok {
		return nil, ErrDecrypt
	}
	return out, nil
}

// MaxVarPlainLen 是变量明文（JSON）的最大字节数（docs/protocol.md 2.6）。
const MaxVarPlainLen = 512 << 10

// Entry 是一个变量的值和备注，两者一起加密（docs/protocol.md 2.6）。
// extra 是本版本不认识的字段（紧凑 JSON 对象，没有时为空），改写时原样保留。
type Entry struct {
	Value string
	Note  string
	extra string
}

func varAAD(envID string, keyVersion int, name string) []byte {
	return Canonical("harmonia.var", envID, strconv.Itoa(keyVersion), name)
}

func (e Entry) marshal() ([]byte, error) {
	var extra map[string]json.RawMessage
	if e.extra != "" {
		if err := json.Unmarshal([]byte(e.extra), &extra); err != nil {
			return nil, err
		}
	}
	fields := map[string]any{"value": e.Value}
	for k, v := range extra {
		fields[k] = v
	}
	if e.Note != "" {
		fields["note"] = e.Note
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(fields); err != nil {
		return nil, err
	}
	out := bytes.TrimRight(buf.Bytes(), "\n")
	if len(out) > MaxVarPlainLen {
		return nil, errors.New("变量内容太长")
	}
	return out, nil
}

func unmarshalEntry(plain []byte) (Entry, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(plain, &fields); err != nil || fields == nil {
		return Entry{}, ErrDecrypt
	}
	var e Entry
	raw, ok := fields["value"]
	if !ok || json.Unmarshal(raw, &e.Value) != nil {
		return Entry{}, ErrDecrypt
	}
	if raw, ok := fields["note"]; ok && json.Unmarshal(raw, &e.Note) != nil {
		return Entry{}, ErrDecrypt
	}
	delete(fields, "value")
	delete(fields, "note")
	if len(fields) > 0 {
		extra, err := json.Marshal(fields)
		if err != nil {
			return Entry{}, ErrDecrypt
		}
		e.extra = string(extra)
	}
	return e, nil
}

// EncryptVar 返回 b64(nonce ‖ ciphertext ‖ tag)，明文是 JSON 对象（docs/protocol.md 2.6）。
func EncryptVar(envKey []byte, envID string, keyVersion int, name string, e Entry) (string, error) {
	plain, err := e.marshal()
	if err != nil {
		return "", err
	}
	aead, err := chacha20poly1305.NewX(envKey)
	if err != nil {
		return "", err
	}
	nonce := Random(chacha20poly1305.NonceSizeX)
	return B64(aead.Seal(nonce, nonce, plain, varAAD(envID, keyVersion, name))), nil
}

func DecryptVar(envKey []byte, envID string, keyVersion int, name, ciphertext string) (Entry, error) {
	plain, err := openVar(envKey, ciphertext, varAAD(envID, keyVersion, name))
	if err != nil {
		return Entry{}, ErrDecrypt
	}
	return unmarshalEntry(plain)
}

func openVar(envKey []byte, ciphertext string, aad []byte) ([]byte, error) {
	raw, err := UnB64(ciphertext)
	if err != nil || len(raw) < chacha20poly1305.NonceSizeX+chacha20poly1305.Overhead {
		return nil, ErrDecrypt
	}
	aead, err := chacha20poly1305.NewX(envKey)
	if err != nil {
		return nil, err
	}
	n := chacha20poly1305.NonceSizeX
	return aead.Open(nil, raw[:n], raw[n:], aad)
}

// ---- 签名原文 ----

func DeviceCertMsg(deviceID, kind, signPub, boxPub string) []byte {
	return Canonical("harmonia.device", deviceID, kind, signPub, boxPub)
}

func EnvelopeMsg(envID string, keyVersion int, recipient string, sealed []byte) []byte {
	return Canonical("harmonia.envelope", envID, strconv.Itoa(keyVersion), recipient, B64(SHA256(sealed)))
}

func RootRecoveryMsg(generation int, sealed []byte) []byte {
	return Canonical("harmonia.root-recovery", strconv.Itoa(generation), B64(SHA256(sealed)))
}

func AuthMsg(deviceID, nonce string) []byte { return Canonical("harmonia.auth", deviceID, nonce) }

func RecoveryAuthMsg(nonce string) []byte { return Canonical("harmonia.recovery-auth", nonce) }

// ---- 恢复码 ----

type RecoveryKeys struct {
	Sign SignKey
	Box  BoxKey
}

func DeriveRecovery(code []byte) RecoveryKeys {
	return RecoveryKeys{
		Sign: SignKeyFromSeed(HKDF(code, "harmonia.recovery.sign")),
		Box:  BoxKeyFromSeed(HKDF(code, "harmonia.recovery.box")),
	}
}

func FormatRecoveryCode(code []byte) string { return group(b32.EncodeToString(code)) }

func ParseRecoveryCode(s string) ([]byte, error) {
	s = strings.ToUpper(strings.NewReplacer("-", "", " ", "", "\t", "", "\n", "").Replace(s))
	s = strings.NewReplacer("O", "0", "I", "1", "L", "1").Replace(s)
	b, err := b32.DecodeString(s)
	if err != nil || len(b) != 16 {
		return nil, errors.New("恢复码格式不对，请检查是否完整输入了 26 个字符")
	}
	return b, nil
}

// ---- 配对 ----

func PairingFingerprint(pairingID, signPub, boxPub, rootPub string) []byte {
	return SHA256(Canonical("harmonia.pairing", pairingID, signPub, boxPub, rootPub))
}

func PairingCode(fp []byte) string { return group(b32.EncodeToString(fp[:10])) }

func PairingQR(pairingID string, fp []byte) string {
	return "harmonia-pair:" + pairingID + ":" + B64(fp)
}

func group(s string) string {
	var parts []string
	for len(s) > 4 {
		parts = append(parts, s[:4])
		s = s[4:]
	}
	return strings.Join(append(parts, s), "-")
}
