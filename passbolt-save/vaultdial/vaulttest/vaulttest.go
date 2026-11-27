// Package vaulttest is what the vault's connection tests share: a key that
// signs in as no one, and an https server on loopback that counts who
// connects to it. Only tests import it.
package vaulttest

import (
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"

	"github.com/ProtonMail/gopenpgp/v3/crypto"
)

const Passphrase = "fixture-passphrase"

func Key(t testing.TB) string {
	t.Helper()
	pgp := crypto.PGP()
	key, err := pgp.KeyGeneration().AddUserId("Fixture", "fixture@example.test").New().GenerateKey()
	if err != nil {
		t.Fatal("fixture key generation failed")
	}
	defer key.ClearPrivateParams()
	locked, err := pgp.LockKey(key, []byte(Passphrase))
	if err != nil {
		t.Fatal("fixture key lock failed")
	}
	armor, err := locked.Armor()
	if err != nil {
		t.Fatal("fixture key encoding failed")
	}
	return armor
}

func Server(t testing.TB) (port string, reached *atomic.Int32) {
	t.Helper()
	reached = new(atomic.Int32)
	server := httptest.NewUnstartedServer(http.NotFoundHandler())
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.Config.ConnState = func(_ net.Conn, state http.ConnState) {
		if state == http.StateNew {
			reached.Add(1)
		}
	}
	server.StartTLS()
	t.Cleanup(server.Close)
	_, port, _ = net.SplitHostPort(server.Listener.Addr().String())
	return port, reached
}
