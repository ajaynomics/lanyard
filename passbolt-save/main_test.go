package main

import "testing"

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
