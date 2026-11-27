package main

import (
	"bytes"
	"encoding/json"
	"encoding/pem"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ProtonMail/gopenpgp/v3/crypto"
	"github.com/passbolt/go-passbolt/api"
)

const readerID = "22222222-2222-4222-8222-222222222222"
const readerType = "33333333-3333-4333-8333-333333333333"
const readerV5ID = "88888888-8888-4888-8888-888888888888"
const readerV5Type = "99999999-9999-4999-8999-999999999999"
const readerSharedID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
const readerSharedType = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
const readerMetadataKey = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
const readerUser = "11111111-1111-4111-8111-111111111111"
const readerPassphrase = "fixture-passphrase"
const readerChallenge = "gpgauthv1.3.0|36|66666666-6666-4666-8666-666666666666|gpgauthv1.3.0"

// The fixture launches the Ruby program before it receives generated material
// on stdin. The application code then runs with child creation forbidden.
func TestProductReaderRubyHTTPS(t *testing.T) {
	if os.Getenv("PASSBOLT_READER_PROOF_LIBRARY") == "" {
		t.Skip("build the c-shared reader and set PASSBOLT_READER_PROOF_LIBRARY")
	}
	pgp := crypto.PGP()
	key, err := pgp.KeyGeneration().AddUserId("Fixture", "fixture@example.test").New().GenerateKey()
	if err != nil {
		t.Fatal("fixture key generation failed")
	}
	defer key.ClearPrivateParams()
	locked, err := pgp.LockKey(key, []byte(readerPassphrase))
	if err != nil {
		t.Fatal("fixture key lock failed")
	}
	armor, err := locked.Armor()
	if err != nil {
		t.Fatal("fixture key encoding failed")
	}
	challenge := readerSeal(t, key, readerChallenge)
	secret := readerSeal(t, key, `{"password":"fixture-password","description":"Account: fixture-account"}`)
	releaseSecret := readerSeal(t, key, `{"password":"synthetic_release_read_value"}`)
	row := api.Resource{ID: readerID, ResourceTypeID: readerType, Name: "Library", URI: "https://library.example", Username: "reader"}
	kind := api.ResourceType{ID: readerType, Slug: "password-and-description"}
	metadata := readerSeal(t, key, `{"object_type":"PASSBOLT_RESOURCE_METADATA","name":"Ledger","uris":["https://ledger.example"],"custom_fields":[{"id":"44444444-4444-4444-8444-444444444444","type":"password","metadata_key":"First library?"}]}`)
	v5Secret := readerSeal(t, key, `{"object_type":"PASSBOLT_SECRET_DATA","custom_fields":[{"id":"44444444-4444-4444-8444-444444444444","type":"password","secret_value":"fixture-answer"}]}`)
	v5Row := api.Resource{ID: readerV5ID, ResourceTypeID: readerV5Type, Metadata: metadata, MetadataKeyType: api.MetadataKeyTypeUserKey}
	v5Kind := api.ResourceType{ID: readerV5Type, Slug: "v5-custom-fields"}
	sharedKey, err := pgp.KeyGeneration().AddUserId("Shared fixture metadata", "shared@example.test").New().GenerateKey()
	if err != nil {
		t.Fatal("fixture shared key generation failed")
	}
	defer sharedKey.ClearPrivateParams()
	sharedArmor, err := sharedKey.Armor()
	if err != nil {
		t.Fatal("fixture shared key encoding failed")
	}
	keyData, err := json.Marshal(api.MetadataPrivateKeyData{ObjectType: "PASSBOLT_METADATA_PRIVATE_KEY", Fingerprint: sharedKey.GetFingerprint(), ArmoredKey: sharedArmor})
	if err != nil {
		t.Fatal("fixture shared key data encoding failed")
	}
	defer clear(keyData)
	shareUser := readerUser
	sharedKeys := []api.MetadataKey{{ID: readerMetadataKey, Fingerprint: sharedKey.GetFingerprint(), MetadataPrivateKeys: []api.MetadataPrivateKey{
		{MetadataKeyID: readerMetadataKey, UserID: &shareUser, Data: readerSeal(t, key, string(keyData))},
	}}}
	shared := readerSeal(t, sharedKey, `{"object_type":"PASSBOLT_RESOURCE_METADATA","name":"Shared","username":"shared-reader","uris":["https://shared.example"]}`)
	sharedSecret := readerSeal(t, key, `{"object_type":"PASSBOLT_SECRET_DATA","password":"fixture-shared-password"}`)
	sharedRow := api.Resource{ID: readerSharedID, ResourceTypeID: readerSharedType, Metadata: shared, MetadataKeyType: api.MetadataKeyTypeSharedKey, MetadataKeyID: readerMetadataKey}
	sharedKind := api.ResourceType{ID: readerSharedType, Slug: "v5-default"}
	redirectTarget := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		t.Error("vault request followed a redirect")
		w.WriteHeader(http.StatusForbidden)
	}))
	defer redirectTarget.Close()
	handler := func(w http.ResponseWriter, r *http.Request) {
		var body any
		status, message, code := "success", "", http.StatusOK
		if strings.HasPrefix(r.URL.Path, "/redirect/") {
			http.Redirect(w, r, redirectTarget.URL, http.StatusTemporaryRedirect)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/denied/") {
			w.WriteHeader(http.StatusForbidden)
			_, _ = io.WriteString(w, "fixture-denial-body")
			return
		}
		swapped := strings.HasPrefix(r.URL.Path, "/swapped/")
		release := !swapped && !strings.HasPrefix(r.URL.Path, "/vault/")
		path := strings.TrimPrefix(r.URL.Path, "/vault")
		if swapped {
			path = strings.TrimPrefix(path, "/swapped")
		}
		route := r.Method + " " + path
		if route != "POST /auth/login.json" {
			cookie, err := r.Cookie("passbolt_session")
			if err != nil || cookie.Value != "fixture-session" {
				t.Error("read reached vault without the authenticated session")
				w.WriteHeader(http.StatusForbidden)
				return
			}
		}
		switch route {
		case "POST /auth/login.json":
			var login api.Login
			if json.NewDecoder(r.Body).Decode(&login) != nil || login.Auth == nil || login.Auth.KeyID != key.GetFingerprint() {
				status, code = "error", http.StatusForbidden
			} else if login.Auth.Token == "" {
				status, message, code = "error", "The authentication failed.", http.StatusUnauthorized
				w.Header().Set("X-GPGAuth-User-Auth-Token", url.QueryEscape(challenge))
			} else if login.Auth.Token == readerChallenge {
				http.SetCookie(w, &http.Cookie{Name: "passbolt_session", Value: "fixture-session", Path: "/vault"})
				http.SetCookie(w, &http.Cookie{Name: "csrfToken", Value: "fixture-csrf", Path: "/vault"})
			} else {
				status, code = "error", http.StatusForbidden
			}
		case "POST /auth/logout.json", "GET /settings.json":
			body = map[string]any{}
		case "GET /users/me.json":
			body = api.User{ID: readerUser}
		case "GET /metadata/keys.json":
			body = sharedKeys
		case "GET /resources.json":
			body = []api.Resource{row, v5Row, sharedRow}
		case "GET /resources/" + readerID + ".json":
			body = row
			if release {
				copy := row
				copy.URI = "https://api.cloudflare.com"
				body = copy
			}
		case "GET /resource-types/" + readerType + ".json":
			body = kind
		case "GET /secrets/resource/" + readerID + ".json":
			result := api.Secret{Data: secret, ResourceID: readerID, UserID: readerUser}
			if release {
				result.Data = releaseSecret
			} else if swapped {
				result.ResourceID = readerV5ID
			}
			body = result
		case "GET /resources/" + readerV5ID + ".json":
			body = v5Row
		case "GET /resource-types/" + readerV5Type + ".json":
			body = v5Kind
		case "GET /secrets/resource/" + readerV5ID + ".json":
			body = api.Secret{Data: v5Secret}
		case "GET /resources/" + readerSharedID + ".json":
			body = sharedRow
		case "GET /resource-types/" + readerSharedType + ".json":
			body = sharedKind
		case "GET /secrets/resource/" + readerSharedID + ".json":
			body = api.Secret{Data: sharedSecret}
		default:
			t.Error("unexpected fixture method or route")
			status, code = "error", http.StatusForbidden
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(code)
		_ = json.NewEncoder(w).Encode(map[string]any{"header": map[string]any{"status": status, "message": message, "code": code}, "body": body})
	}
	server := httptest.NewUnstartedServer(http.HandlerFunc(handler))
	server.Config.ErrorLog = log.New(io.Discard, "", 0)
	server.StartTLS()
	defer server.Close()
	ca := filepath.Join(t.TempDir(), "fixture-ca.pem")
	if err := os.WriteFile(ca, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: server.Certificate().Raw}), 0600); err != nil {
		t.Fatal("fixture certificate write failed")
	}
	input, err := json.Marshal(map[string]string{
		"url": server.URL + "/vault", "private_key": armor, "passphrase": readerPassphrase, "id": readerID, "v5_id": readerV5ID, "shared_id": readerSharedID,
		"redirect_url": server.URL + "/redirect", "denied_url": server.URL + "/denied",
		"swapped_url": server.URL + "/swapped", "release_origin": server.URL, "user_id": readerUser, "type_id": readerType,
	})
	if err != nil {
		t.Fatal("fixture input encoding failed")
	}
	defer clear(input)
	for _, mode := range []string{"read", "untrusted"} {
		t.Run(mode, func(t *testing.T) {
			ruby := exec.Command("ruby", "testdata/https-reader.rb", mode)
			ruby.Stdin = bytes.NewReader(input)
			if mode == "read" {
				ruby.Env = append(os.Environ(), "SSL_CERT_FILE="+ca)
			} else {
				ruby.Env = append(os.Environ(), "SSL_CERT_FILE="+os.DevNull)
			}
			output, err := ruby.CombinedOutput()
			if err != nil {
				// The harness uses identifiers, never key/value dumps, in failures.
				t.Fatalf("Ruby read failed: %s", output)
			}
		})
	}
}

func readerSeal(t *testing.T, key *crypto.Key, value string) string {
	t.Helper()
	enc, err := crypto.PGP().Encryption().Recipient(key).New()
	if err != nil {
		t.Fatal("fixture encryptor setup failed")
	}
	message, err := enc.Encrypt([]byte(value))
	if err != nil {
		t.Fatal("fixture encryption failed")
	}
	armor, err := message.Armor()
	if err != nil {
		t.Fatal("fixture encoding failed")
	}
	return armor
}
