package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/ajaynomics/durable-assistants/passbolt-save/vaultdial"
	"github.com/passbolt/go-passbolt/api"
	"github.com/passbolt/go-passbolt/helper"
)

const productLimit = 8 << 20

var errProduct = errors.New("saved sign-in unavailable")
var productReadPath = regexp.MustCompile(`^/(resources|resource-types|secrets/resource)/[a-f0-9-]{36}\.json$`)

type productCall struct {
	Operation, ID string
}

type productVault struct {
	Origin, Key, Passphrase string
	InternalHosts           string `json:"internal_hosts"`
}

func (v productVault) call(req productCall) (any, error) {
	switch req.Operation {
	case "list":
	case "read":
		if !uuid.MatchString(req.ID) {
			return nil, errProduct
		}
	default:
		return nil, errProduct
	}
	origin, err := url.Parse(v.Origin)
	if err != nil || origin.Hostname() == "" || origin.User != nil || origin.RawQuery != "" || origin.ForceQuery || origin.Fragment != "" || origin.RawPath != "" ||
		origin.Scheme != "https" || v.Key == "" || v.Passphrase == "" {
		return nil, errProduct
	}
	// Only the configured HTTPS origin is in scope. No proxy, alternate
	// origin, redirect or TLS fallback, and no connection inside unless
	// Rails lists its host.
	wire := vaultdial.Transport(v.InternalHosts)
	defer wire.CloseIdleConnections()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	guard := productTransport{origin: origin, wire: wire, operation: req.Operation, id: req.ID}
	guard.deadline, _ = ctx.Deadline()
	client, err := api.NewClient(&http.Client{Transport: guard, Timeout: 30 * time.Second}, "SavedSignIns", v.Origin, v.Key, v.Passphrase)
	if err != nil {
		return nil, errProduct
	}
	defer client.ClearCache()
	if client.Login(ctx) != nil {
		return nil, errProduct
	}
	defer func() { _ = client.Logout(ctx) }()
	if !uuid.MatchString(client.GetUserID()) {
		return nil, errProduct
	}
	switch req.Operation {
	case "list":
		return productList(ctx, client)
	case "read":
		return productRead(ctx, client, req)
	}
	return nil, errProduct
}

func productList(ctx context.Context, client *api.Client) ([]map[string]string, error) {
	rows, err := client.GetResources(ctx, nil)
	if err != nil {
		return nil, errProduct
	}
	out := make([]map[string]string, 0, len(rows))
	for _, row := range rows {
		if !uuid.MatchString(row.ID) {
			return nil, errProduct
		}
		name, site := row.Name, row.URI
		if row.Metadata != "" {
			if !uuid.MatchString(row.ResourceTypeID) {
				return nil, errProduct
			}
			kind, err := client.GetResourceType(ctx, row.ResourceTypeID)
			if err != nil || kind.ID != row.ResourceTypeID {
				return nil, errProduct
			}
			raw, err := helper.GetResourceMetadata(ctx, client, &row, kind)
			var fields map[string]any
			if err != nil || json.Unmarshal([]byte(raw), &fields) != nil {
				return nil, errProduct
			}
			name, site = helper.GetStringField(fields, "name"), productURI(fields)
		}
		out = append(out, map[string]string{"id": row.ID, "name": name, "uri": site})
	}
	return out, nil
}

func productRead(ctx context.Context, client *api.Client, req productCall) (any, error) {
	row, err := client.GetResource(ctx, req.ID)
	if err != nil || row.ID != req.ID || !uuid.MatchString(row.ResourceTypeID) {
		return nil, errProduct
	}
	kind, err := client.GetResourceType(ctx, row.ResourceTypeID)
	if err != nil || kind.ID != row.ResourceTypeID {
		return nil, errProduct
	}
	secret, err := client.GetSecret(ctx, req.ID)
	if err != nil || (secret.ResourceID != "" && secret.ResourceID != req.ID) || (secret.UserID != "" && secret.UserID != client.GetUserID()) {
		return nil, errProduct
	}
	_, meta, values, err := helper.GetResourceFieldMaps(client, *row, *secret, *kind, true)
	if err != nil {
		return nil, errProduct
	}
	password := helper.GetStringField(values, "password")
	description := helper.GetStringField(values, "description")
	if description == "" {
		description = helper.GetStringField(meta, "description")
	}
	return map[string]any{
		"name": helper.GetStringField(meta, "name"), "uri": productURI(meta), "username": helper.GetStringField(meta, "username"),
		"password": password, "description": description,
		"metadata": map[string]any{"custom_fields": meta["custom_fields"]},
		"secret":   map[string]any{"custom_fields": values["custom_fields"]},
	}, nil
}

func productURI(fields map[string]any) string {
	if uri := helper.GetStringField(fields, "uri"); uri != "" {
		return uri
	}
	if uris, ok := fields["uris"].([]any); ok && len(uris) > 0 {
		uri, _ := uris[0].(string)
		return uri
	}
	return ""
}

type productTransport struct {
	origin        *url.URL
	wire          http.RoundTripper
	deadline      time.Time
	operation, id string
}

func (t productTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.URL.Scheme != t.origin.Scheme || r.URL.Host != t.origin.Host || r.URL.User != nil || r.URL.RawPath != "" {
		return nil, errProduct
	}
	prefix := strings.TrimRight(path.Clean("/"+t.origin.Path), "/")
	rel := strings.TrimPrefix(r.URL.Path, prefix+"/")
	if rel == r.URL.Path || !t.allows(r.Method, "/"+rel) {
		return nil, errProduct
	}
	// Some SDK decode helpers use context.TODO. Every exchange still shares
	// the caller's absolute budget, even when decoding metadata needs I/O.
	ctx, cancel := context.WithDeadline(r.Context(), t.deadline)
	defer cancel()
	resp, err := t.wire.RoundTrip(r.WithContext(ctx))
	if err != nil {
		return nil, errProduct
	}
	defer resp.Body.Close()
	challenge := r.Method == "POST" && rel == "auth/login.json" && resp.StatusCode == http.StatusUnauthorized && resp.Header.Get("X-GPGAuth-User-Auth-Token") != ""
	if (!challenge && (resp.StatusCode < 200 || resp.StatusCode >= 300)) || resp.ContentLength > productLimit {
		return nil, errProduct
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, productLimit+1))
	if err != nil || len(body) > productLimit {
		return nil, errProduct
	}
	resp.Body = io.NopCloser(bytes.NewReader(body))
	return resp, nil
}

func (t productTransport) allows(method, route string) bool {
	switch method {
	case "GET":
		switch route {
		case "/users/me.json", "/settings.json", "/metadata/types/settings.json", "/metadata/keys/settings.json",
			"/metadata/keys.json", "/metadata/session-keys.json", "/password-expiry/settings.json":
			return true
		case "/resources.json":
			return t.operation == "list"
		}
		if !productReadPath.MatchString(route) {
			return false
		}
		return strings.HasPrefix(route, "/resource-types/") || route == "/resources/"+t.id+".json" || route == "/secrets/resource/"+t.id+".json"
	case "POST":
		return route == "/auth/login.json" || route == "/auth/logout.json"
	}
	return false
}
