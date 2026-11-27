package main

import (
	"context"
	"strings"
	"testing"

	"github.com/ajaynomics/durable-assistants/passbolt-save/vaultdial/vaulttest"
	"github.com/passbolt/go-passbolt/api"
)

func TestWithAccount(t *testing.T) {
	cases := []struct{ description, account, want string }{
		{"", "12345", "Account: 12345"},
		{"Branch: Main Street", "12345", "Account: 12345\nBranch: Main Street"},
		{"Branch: Main Street\nACCOUNT:   old  \nAccount: 99999", "12345", "Branch: Main Street\nAccount: 12345\nAccount: 99999"},
		{"  account: old\r\nNote", "12345", "Account: 12345\r\nNote"},
		{"Accounts payable: Jo\nNote", "12345", "Account: 12345\nAccounts payable: Jo\nNote"},
	}
	for _, c := range cases {
		if got := withAccount(c.description, c.account); got != c.want {
			t.Errorf("withAccount(%q, %q) = %q, want %q", c.description, c.account, got, c.want)
		}
	}
}

// A vault server whose name now resolves to this machine is refused as the
// save connects, unless Rails lists its host as one inside the install.
func TestASaveReachesInsideOnlyAListedHost(t *testing.T) {
	port, reached := vaulttest.Server(t)
	t.Setenv("SERVERADDRESS", "https://localhost:"+port)
	t.Setenv("USERPRIVATEKEY", vaulttest.Key(t))
	t.Setenv("USERPASSWORD", vaulttest.Passphrase)
	work := func(context.Context, *api.Client) (string, error) { return "", nil }

	if err := withClient(work); err == nil || !strings.Contains(err.Error(), "private network") || reached.Load() != 0 {
		t.Fatalf("reached the server inside %d times: %v", reached.Load(), err)
	}
	t.Setenv("INTERNAL_HOSTS", "localhost:"+port)
	if withClient(work) == nil || reached.Load() == 0 {
		t.Error("the listed host was never reached, or signed in with a certificate no one trusts")
	}
}
