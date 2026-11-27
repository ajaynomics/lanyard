// passbolt-save saves one new sign-in to Passbolt, as `passbolt create
// resource` does, but reads it from standard input: go-passbolt-cli (0.5.3)
// takes a password only as an argument, and every local account can read a
// process's arguments. One JSON object in, {"name","uri","username",
// "password"}; the server, key and passphrase from the environment, as the
// CLI reads them, and the hosts inside it may reach in INTERNAL_HOSTS
// (vaultdial); {"id": "..."} out. lib/durable_assistants/passbolt.rb runs it.
//
// `passbolt-save fill` fills an existing, empty entry instead (SignInLink):
// {"id","username","password","account"} in, the same {"id"} out. It refuses
// an entry that already has a password, so nothing is ever overwritten.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/ajaynomics/durable-assistants/passbolt-save/vaultdial"
	"github.com/passbolt/go-passbolt/api"
	"github.com/passbolt/go-passbolt/helper"
)

func main() {
	run := save
	if len(os.Args) > 1 && os.Args[1] == "fill" {
		run = fill
	}
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "passbolt-save:", err)
		os.Exit(1)
	}
}

func save() error {
	var entry struct{ Name, URI, Username, Password string }
	if err := json.NewDecoder(os.Stdin).Decode(&entry); err != nil {
		return fmt.Errorf("reading the sign-in: %w", err)
	}
	if entry.Name == "" || entry.Password == "" {
		return fmt.Errorf("a sign-in needs a name and a password")
	}

	return withClient(func(ctx context.Context, client *api.Client) (string, error) {
		return helper.CreateResource(ctx, client, "", entry.Name, entry.Username, entry.URI, entry.Password, "")
	})
}

func fill() error {
	var entry struct{ ID, Username, Password, Account string }
	if err := json.NewDecoder(os.Stdin).Decode(&entry); err != nil {
		return fmt.Errorf("reading the sign-in: %w", err)
	}
	if entry.ID == "" || entry.Password == "" {
		return fmt.Errorf("a fill needs an entry and a password")
	}
	if strings.ContainsAny(entry.Account, "\r\n") {
		return fmt.Errorf("an account is one line")
	}

	return withClient(func(ctx context.Context, client *api.Client) (string, error) {
		return entry.ID, fillEntry(ctx, client, entry.ID, entry.Username, entry.Password, entry.Account)
	})
}

// fillEntry writes the sign-in into an entry with no password. go-passbolt's
// UpdateResource keeps every field it is not given and encrypts the secret
// again for each user the entry is shared with, so they all can read it.
func fillEntry(ctx context.Context, client *api.Client, id, username, password, account string) error {
	resource, err := client.GetResource(ctx, id)
	if err != nil {
		return fmt.Errorf("getting the entry: %w", err)
	}
	resourceType, err := client.GetResourceType(ctx, resource.ResourceTypeID)
	if err != nil {
		return fmt.Errorf("getting the entry's type: %w", err)
	}
	_, _, _, _, current, description, err := helper.GetResource(ctx, client, id)
	if err != nil {
		return err
	}
	if current != "" {
		return errors.New("the entry already has a password, and it is never overwritten")
	}
	if account != "" {
		// A v4 entry whose type keeps the description outside its secret
		// stores it in the clear; an account goes only where it is encrypted.
		if resource.Metadata == "" && !resourceType.HasSecretField("description") {
			return errors.New("this entry's description is not encrypted, so it can't hold an account")
		}
		description = withAccount(description, account)
	}
	return helper.UpdateResource(ctx, client, id, "", username, "", password, description)
}

var accountLine = regexp.MustCompile(`(?im)^[ \t]*account[ \t]*:[^\r\n]*`)

// The description with its first "Account: ..." line, the one the app reads
// (DurableAssistants::Passbolt.account_in), set to this account, or one put
// first when it has none. Every other line stays as it was.
func withAccount(description, account string) string {
	line := "Account: " + account
	if location := accountLine.FindStringIndex(description); location != nil {
		return description[:location[0]] + line + description[location[1]:]
	}
	if description == "" {
		return line
	}
	return line + "\n" + description
}

func withClient(work func(context.Context, *api.Client) (string, error)) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	// Each connection, a redirect's too, is refused if it lands inside
	// unless Rails lists its host (INTERNAL_HOSTS).
	wire := &http.Client{Transport: vaultdial.Transport(os.Getenv("INTERNAL_HOSTS"))}
	client, err := api.NewClient(wire, "", os.Getenv("SERVERADDRESS"), os.Getenv("USERPRIVATEKEY"), os.Getenv("USERPASSWORD"))
	if err != nil {
		return err
	}
	if err := client.Login(ctx); err != nil {
		return err
	}
	id, err := work(ctx, client)
	// The entry is saved or not by now; a failed logout only leaves a
	// session to expire, so it must not report a saved entry as unsaved.
	if logoutErr := client.Logout(ctx); logoutErr != nil {
		fmt.Fprintln(os.Stderr, "passbolt-save: logout:", logoutErr)
	}
	if err != nil {
		return err
	}
	return json.NewEncoder(os.Stdout).Encode(map[string]string{"id": id})
}
