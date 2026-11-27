package main

import (
	"testing"

	"github.com/ajaynomics/durable-assistants/passbolt-save/vaultdial/vaulttest"
)

// The reader refuses a vault server whose name now resolves to this machine
// as it connects, unless Rails lists its host as one inside the install.
func TestTheReaderReachesInsideOnlyAListedHost(t *testing.T) {
	port, reached := vaulttest.Server(t)
	vault := productVault{Origin: "https://localhost:" + port, Key: vaulttest.Key(t), Passphrase: vaulttest.Passphrase}

	if _, err := vault.call(productCall{Operation: "list"}); err == nil || reached.Load() != 0 {
		t.Fatalf("reached the server inside %d times", reached.Load())
	}
	vault.InternalHosts = "localhost:" + port
	if _, err := vault.call(productCall{Operation: "list"}); err == nil || reached.Load() == 0 {
		t.Error("the listed host was never reached, or read with a certificate no one trusts")
	}
}
