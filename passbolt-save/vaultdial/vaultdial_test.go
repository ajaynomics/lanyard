package vaultdial

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/ajaynomics/durable-assistants/passbolt-save/vaultdial/vaulttest"
)

// What the hook is handed once a name is looked up, never dialled, so no
// test reaches past this machine. The addresses McpServer::Address.internal?
// refuses (test/models/mcp_server_test.rb) and lets through.
func TestTheHookRefusesWhatALookupReturnsInside(t *testing.T) {
	for _, address := range []string{"127.0.0.1", "10.0.0.5", "169.254.169.254", "[::ffff:10.0.0.1]", "[::ffff:169.254.169.254]",
		"[::10.0.0.1]", "[::1]", "[::]", "0.0.0.0", "0.0.0.1", "100.64.0.1", "172.16.0.1", "192.168.1.1", "[fd00::1]", "[fe80::1%eth0]", "nonsense"} {
		if refuseInternal("tcp", address+":443", nil) == nil {
			t.Errorf("%s was let through", address)
		}
	}
	for _, address := range []string{"203.0.113.10", "8.8.8.8", "172.32.0.1", "100.128.0.1", "[2606:4700::1111]", "[2001:db8::1]", "[::ffff:8.8.8.8]"} {
		if err := refuseInternal("tcp", address+":443", nil); err != nil {
			t.Errorf("%s was refused: %v", address, err)
		}
	}
}

// "localhost" is looked up as it is dialled, as any name a vault server
// could rebind to this machine would be. Only a listed host gets through.
func TestDialRefusesInsideButWhatIsListed(t *testing.T) {
	port, reached := vaulttest.Server(t)
	dial := func(listed, address string) error {
		conn, err := Dial(listed)(context.Background(), "tcp", address)
		if err == nil {
			conn.Close()
		}
		return err
	}
	for _, address := range []string{"127.0.0.1:" + port, "[::ffff:127.0.0.1]:" + port, "localhost:" + port} {
		if err := dial("", address); err == nil || !strings.Contains(err.Error(), "private network") {
			t.Errorf("%s was not refused for being inside: %v", address, err)
		}
	}
	for _, listed := range []string{"localhost:1", "localhost.example", "127.0.0.1", "localhost:" + port + "0", "localhost:abc"} {
		if dial(listed, "localhost:"+port) == nil {
			t.Errorf("listed as %q, let through", listed)
		}
	}
	if n := reached.Load(); n != 0 {
		t.Fatalf("reached %d times while refused", n)
	}
	for _, listed := range []string{"localhost", "LocalHost:" + port, "other,  localhost:" + port} {
		if err := dial(listed, "localhost:"+port); err != nil {
			t.Errorf("listed as %q, still refused: %v", listed, err)
		}
	}
}

// A listed server redirecting to an unlisted one inside: that hop is
// refused as it connects, whatever the client's redirect policy.
func TestARedirectIsCheckedAsItConnects(t *testing.T) {
	var inside atomic.Int32
	target := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { inside.Add(1) }))
	defer target.Close()
	listed := httptest.NewServer(http.RedirectHandler(target.URL+"/secret", http.StatusFound))
	defer listed.Close()
	_, port, _ := net.SplitHostPort(listed.Listener.Addr().String())

	response, err := (&http.Client{Transport: Transport("localhost:" + port)}).Get("http://localhost:" + port + "/")
	if err == nil {
		response.Body.Close()
	}
	if err == nil || !strings.Contains(err.Error(), "private network") || inside.Load() != 0 {
		t.Errorf("the redirect inside was followed: %v", err)
	}
}
