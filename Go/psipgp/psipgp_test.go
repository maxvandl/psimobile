package psipgp

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Проверяет совместимость с настоящим gpg на одноразовых ключах. Нужен gpg; ключи пользователя не затрагиваются.

type gpgHome struct {
	t    *testing.T
	home string
}

func newHome(t *testing.T) *gpgHome {
	dir, err := os.MkdirTemp("", "psipgp")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		exec.Command("gpgconf", "--homedir", dir, "--kill", "all").Run()
		os.RemoveAll(dir)
	})
	return &gpgHome{t, dir}
}

func (g *gpgHome) run(stdin string, args ...string) string {
	g.t.Helper()
	all := append([]string{"--homedir", g.home, "--batch", "--yes", "--trust-model", "always", "--pinentry-mode", "loopback", "--passphrase", ""}, args...)
	cmd := exec.Command("gpg", all...)
	cmd.Stdin = strings.NewReader(stdin)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		g.t.Fatalf("gpg %v: %v\n%s", args, err, errb.String())
	}
	return out.String()
}

func (g *gpgHome) key(uid, algo string) (public, secret string) {
	g.run("", "--quick-generate-key", uid, algo, "default", "never")
	switch algo {
	case "dsa2048":
		g.run("", "--quick-add-key", g.fingerprint(uid), "elg2048", "encr", "never")
	case "rsa2048":
		g.run("", "--quick-add-key", g.fingerprint(uid), "rsa2048", "encr", "never")
	}
	return g.run("", "--armor", "--export", uid), g.run("", "--armor", "--export-secret-keys", uid)
}

func (g *gpgHome) fingerprint(uid string) string {
	for _, line := range strings.Split(g.run("", "--with-colons", "--fingerprint", uid), "\n") {
		if strings.HasPrefix(line, "fpr:") {
			return strings.Split(line, ":")[9]
		}
	}
	g.t.Fatal("no fingerprint")
	return ""
}

func TestGPGInterop(t *testing.T) {
	for _, algo := range []string{"rsa2048", "dsa2048", "future-default"} {
		t.Run(algo, func(t *testing.T) {
			g := newHome(t)
			pub, sec := g.key("me@example.org", algo)
			otherPub, _ := g.key("other@example.org", "rsa2048")
			own, err := NewOwnKey(sec, nil)
			if err != nil {
				t.Fatal(err)
			}

			// gpg -> приложение
			text := "сообщение gpg"
			enc := g.run(text, "--armor", "--encrypt", "-r", "me@example.org")
			if d, err := own.Decrypt(enc, pub); err != nil || d.Text != text || d.Verified {
				t.Fatalf("unsigned: %+v %v", d, err)
			}
			signed := g.run(text, "--armor", "--sign", "--encrypt", "-u", "me@example.org", "-r", "me@example.org")
			if d, err := own.Decrypt(signed, pub); err != nil || d.Text != text || !d.Verified {
				t.Fatalf("signed by sender: %+v %v", d, err)
			}
			if d, err := own.Decrypt(signed, otherPub); err != nil || d.Text != text || d.Verified {
				t.Fatalf("signed by someone else: %+v %v", d, err)
			}

			// приложение -> gpg: на получателя и на себя
			reply, err := Encrypt("ответ", otherPub, sec)
			if err != nil {
				t.Fatal(err)
			}
			if got := g.run(reply, "--decrypt"); got != "ответ" {
				t.Fatalf("gpg decrypt: %q", got)
			}
			if packets := g.run(reply, "--list-packets"); strings.Count(packets, ":pubkey enc packet:") != 2 {
				t.Fatalf("expected two recipients:\n%s", packets)
			}

			// подписи статуса в обе стороны
			sig, err := own.Sign("статус")
			if err != nil {
				t.Fatal(err)
			}
			if !Verify("статус", sig, pub) || Verify("другой статус", sig, pub) || Verify("статус", sig, otherPub) {
				t.Fatal("own signature check")
			}
			sigFile, txtFile := filepath.Join(g.home, "s.asc"), filepath.Join(g.home, "s.txt")
			os.WriteFile(sigFile, []byte(sig), 0o600)
			os.WriteFile(txtFile, []byte("статус"), 0o600)
			g.run("", "--verify", sigFile, txtFile)
			gpgSig := g.run("статус gpg", "--armor", "--detach-sign", "-u", "me@example.org")
			if !Verify("статус gpg", gpgSig, pub) || Verify("подмена", gpgSig, pub) {
				t.Fatal("gpg signature check")
			}

			// отпечаток и ID
			fp, err := Fingerprint(pub)
			if err != nil || !strings.EqualFold(fp, g.fingerprint("me@example.org")) {
				t.Fatalf("fingerprint %q %v", fp, err)
			}
			if id, err := KeyID(pub); err != nil || !strings.HasSuffix(strings.ToUpper(fp), strings.ToUpper(id)) {
				t.Fatalf("key id %q %v", id, err)
			}

			// публичный ключ вместо секретного
			if _, err := NewOwnKey(pub, nil); err == nil {
				t.Fatal("public key accepted as own")
			}
			// секретный ключ контакта не должен раскрываться: шифруем только на публичную часть
			if _, err := Encrypt("x", sec, ""); err != nil {
				t.Fatal(err)
			}
		})
	}

	t.Run("passphrase", func(t *testing.T) {
		g := newHome(t)
		g.run("", "--pinentry-mode", "loopback", "--passphrase", "secret", "--quick-generate-key", "p@example.org", "rsa2048", "default", "never")
		sec := g.run("", "--pinentry-mode", "loopback", "--passphrase", "secret", "--armor", "--export-secret-keys", "p@example.org")
		if _, err := NewOwnKey(sec, []byte("wrong")); err == nil {
			t.Fatal("wrong passphrase accepted")
		}
		if _, err := NewOwnKey(sec, []byte("secret")); err != nil {
			t.Fatal(err)
		}
	})
}
