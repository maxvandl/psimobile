// Package psipgp — тонкая обёртка над GopenPGP только с тем, что нужно приложению.
// Наружу торчат эти функции, а не весь пакет crypto: линковщик Go выбрасывает остальное,
// и бинарник приложения становится заметно меньше.
package psipgp

import (
	"errors"

	"github.com/ProtonMail/gopenpgp/v2/crypto"
)

// Decrypted — результат расшифровки. Verified означает, что сообщение подписано ключом отправителя.
type Decrypted struct {
	Text     string
	Verified bool
}

// OwnKey хранит разблокированный секретный ключ, чтобы не открывать его заново на каждое сообщение.
type OwnKey struct {
	ring *crypto.KeyRing
}

// NewOwnKey открывает секретный ключ паролем.
func NewOwnKey(armored string, passphrase []byte) (*OwnKey, error) {
	key, err := crypto.NewKeyFromArmored(armored)
	if err != nil {
		return nil, err
	}
	if !key.IsPrivate() {
		return nil, errors.New("not a private key")
	}
	unlocked, err := key.Unlock(passphrase)
	if err != nil {
		return nil, err
	}
	ring, err := crypto.NewKeyRing(unlocked)
	if err != nil {
		return nil, err
	}
	return &OwnKey{ring}, nil
}

// Fingerprint возвращает отпечаток ключа.
func Fingerprint(armored string) (string, error) {
	key, err := crypto.NewKeyFromArmored(armored)
	if err != nil {
		return "", err
	}
	return key.GetFingerprint(), nil
}

// KeyID возвращает ID ключа в hex.
func KeyID(armored string) (string, error) {
	key, err := crypto.NewKeyFromArmored(armored)
	if err != nil {
		return "", err
	}
	return key.GetHexKeyID(), nil
}

func publicRing(armored string) (*crypto.KeyRing, error) {
	key, err := crypto.NewKeyFromArmored(armored)
	if err != nil {
		return nil, err
	}
	// ToPublic возвращает ошибку, если ключ уже публичный.
	if key.IsPrivate() {
		if key, err = key.ToPublic(); err != nil {
			return nil, err
		}
	}
	return crypto.NewKeyRing(key)
}

// Encrypt шифрует текст на ключ получателя и, если own не пуст, на публичную часть своего ключа.
func Encrypt(plaintext, recipient, own string) (string, error) {
	ring, err := publicRing(recipient)
	if err != nil {
		return "", err
	}
	if own != "" {
		key, err := crypto.NewKeyFromArmored(own)
		if err != nil {
			return "", err
		}
		public, err := key.ToPublic()
		if err != nil {
			return "", err
		}
		if err := ring.AddKey(public); err != nil {
			return "", err
		}
	}
	message, err := ring.Encrypt(crypto.NewPlainMessageFromString(plaintext), nil)
	if err != nil {
		return "", err
	}
	return message.GetArmored()
}

// Decrypt расшифровывает сообщение. Отсутствие подписи не ошибка: XEP-0027 её не требует.
// Подпись проверяется на текущее время, как и в Verify: нулевое время отключило бы проверку срока.
func (k *OwnKey) Decrypt(armored, sender string) (*Decrypted, error) {
	message, err := crypto.NewPGPMessageFromArmored(armored)
	if err != nil {
		return nil, err
	}
	if sender != "" {
		if ring, err := publicRing(sender); err == nil {
			if plain, err := k.ring.Decrypt(message, ring, crypto.GetUnixTime()); err == nil {
				return &Decrypted{plain.GetString(), true}, nil
			}
		}
	}
	plain, err := k.ring.Decrypt(message, nil, 0)
	if err != nil {
		return nil, err
	}
	return &Decrypted{plain.GetString(), false}, nil
}

// Sign возвращает отделённую подпись текста.
func (k *OwnKey) Sign(text string) (string, error) {
	signature, err := k.ring.SignDetached(crypto.NewPlainMessageFromString(text))
	if err != nil {
		return "", err
	}
	return signature.GetArmored()
}

// Verify проверяет отделённую подпись ключом отправителя.
func Verify(text, armoredSignature, sender string) bool {
	ring, err := publicRing(sender)
	if err != nil {
		return false
	}
	signature, err := crypto.NewPGPSignatureFromArmored(armoredSignature)
	if err != nil {
		return false
	}
	return ring.VerifyDetached(crypto.NewPlainMessageFromString(text), signature, crypto.GetUnixTime()) == nil
}
