// The preview release vault exposes one read operation, not the agent CLI.
package main

import "C"

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"time"
	"unsafe"

	"github.com/passbolt/go-passbolt/api"
	"github.com/passbolt/go-passbolt/helper"
)

const maxReply = 64 << 10

var unavailable = errors.New("preview release vault unavailable")
var uuid = regexp.MustCompile(`^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$`)
var bearer = regexp.MustCompile(`^[A-Za-z0-9_-]{20,256}$`)

type vault struct {
	origin, pem, user, resource, kind, key, passphrase string
}

func (v vault) read() (string, error) {
	u, err := url.Parse(v.origin)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.Path != "" || u.RawQuery != "" || u.ForceQuery || u.Fragment != "" ||
		v.key == "" || v.passphrase == "" || !uuid.MatchString(v.user) || !uuid.MatchString(v.resource) || !uuid.MatchString(v.kind) {
		return "", unavailable
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM([]byte(v.pem)) {
		return "", unavailable
	}
	wire := &http.Transport{TLSClientConfig: &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}, DisableKeepAlives: true}
	defer wire.CloseIdleConnections()
	guard := transport{wire, u.Host, map[string]bool{
		"POST /auth/login.json": true, "POST /auth/logout.json": true,
		"GET /users/me.json": true, "GET /settings.json": true,
		"GET /resources/" + v.resource + ".json":        true,
		"GET /resource-types/" + v.kind + ".json":       true,
		"GET /secrets/resource/" + v.resource + ".json": true,
	}}
	client, err := api.NewClient(&http.Client{Transport: guard, Timeout: 3 * time.Second}, "ReleaseVault", v.origin, v.key, v.passphrase)
	if err != nil {
		return "", unavailable
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if client.Login(ctx) != nil {
		return "", unavailable
	}
	defer func() {
		logout, done := context.WithTimeout(context.Background(), time.Second)
		defer done()
		_ = client.Logout(logout)
	}()
	if client.GetUserID() != v.user {
		return "", unavailable
	}
	resource, err := client.GetResource(ctx, v.resource)
	if err != nil || resource.ID != v.resource || resource.URI != "https://api.cloudflare.com" || resource.ResourceTypeID != v.kind || resource.Metadata != "" {
		return "", unavailable
	}
	kind, err := client.GetResourceType(ctx, v.kind)
	if err != nil || kind.ID != v.kind || kind.Slug != "password-and-description" {
		return "", unavailable
	}
	secret, err := client.GetSecret(ctx, v.resource)
	if err != nil {
		return "", unavailable
	}
	_, _, _, _, value, _, err := helper.GetResourceFromData(client, *resource, *secret, *kind)
	if err != nil || !bearer.MatchString(value) {
		return "", unavailable
	}
	return value, nil
}

type transport struct {
	wire  http.RoundTripper
	host  string
	paths map[string]bool
}

func (t transport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.URL.Scheme != "https" || r.URL.Host != t.host || r.URL.User != nil || !t.paths[r.Method+" "+r.URL.RequestURI()] {
		return nil, unavailable
	}
	resp, err := t.wire.RoundTrip(r)
	if err != nil {
		return nil, unavailable
	}
	challenge := r.Method == "POST" && r.URL.Path == "/auth/login.json" && resp.StatusCode == http.StatusUnauthorized &&
		resp.Header.Get("X-GPGAuth-User-Auth-Token") != ""
	defer resp.Body.Close()
	if ((resp.StatusCode < 200 || resp.StatusCode >= 300) && !challenge) || resp.ContentLength > maxReply {
		return nil, unavailable
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, maxReply+1))
	if err != nil || len(body) > maxReply {
		return nil, unavailable
	}
	resp.Body = io.NopCloser(bytes.NewReader(body))
	return resp, nil
}

//export ReleaseVaultRead
func ReleaseVaultRead(origin, pem, user, record, kind, key, passphrase, out *C.char, capacity C.int) (status C.int) {
	status = -1
	if out == nil || capacity != 257 {
		return
	}
	buf := unsafe.Slice((*byte)(unsafe.Pointer(out)), int(capacity))
	clear(buf)
	defer func() {
		if recover() != nil {
			clear(buf)
			status = -1
		}
	}()
	v := vault{C.GoString(origin), C.GoString(pem), C.GoString(user), C.GoString(record), C.GoString(kind), C.GoString(key), C.GoString(passphrase)}
	value, err := v.read()
	if err != nil {
		return
	}
	copy(buf, value)
	return 0
}

func main() {}
