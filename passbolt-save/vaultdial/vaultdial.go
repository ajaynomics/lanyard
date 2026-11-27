// Package vaultdial connects to a vault server only where Rails would let it.
// Rails checks a workspace's server's name before each call
// (McpServer::Address), but Go looks the name up again when it connects, and
// a rebinding server could answer that second lookup with this machine or the
// private network. So the check is made again here, on the very address each
// connection is about to use, redirects' and retries' included.
package vaultdial

import (
	"context"
	"crypto/tls"
	"fmt"
	"net"
	"net/http"
	"net/netip"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// The addresses McpServer::Address.internal? refuses: loopback, private
// (RFC 1918 and ULA), link-local (the cloud metadata address among them),
// carrier-grade NAT and "this network", which holds the unspecified address
// once inside has read :: as 0.0.0.0.
var internal = []netip.Prefix{
	netip.MustParsePrefix("127.0.0.0/8"), netip.MustParsePrefix("::1/128"),
	netip.MustParsePrefix("10.0.0.0/8"), netip.MustParsePrefix("172.16.0.0/12"),
	netip.MustParsePrefix("192.168.0.0/16"), netip.MustParsePrefix("fc00::/7"),
	netip.MustParsePrefix("169.254.0.0/16"), netip.MustParsePrefix("fe80::/10"),
	netip.MustParsePrefix("100.64.0.0/10"), netip.MustParsePrefix("0.0.0.0/8"),
}

var port = regexp.MustCompile(`\A\d{1,5}\z`)

// inside says whether an address is on this machine or its private network.
// An IPv4-mapped or IPv4-compatible address is judged as the IPv4 address it
// carries, as Ruby's IPAddr#native does. A zone is dropped first, because a
// zoned address matches no prefix at all.
func inside(address netip.Addr) bool {
	address = address.WithZone("").Unmap()
	if bytes := address.As16(); address.Is6() && [12]byte(bytes[:12]) == [12]byte{} {
		address = netip.AddrFrom4([4]byte(bytes[12:]))
	}
	for _, prefix := range internal {
		if prefix.Contains(address) {
			return true
		}
	}
	return !address.IsValid()
}

// Transport makes every connection through Dial, with no proxy, so no hop
// of any request can reach an internal address unless its host is listed.
func Transport(internalHosts string) *http.Transport {
	return &http.Transport{
		Proxy: nil, DisableKeepAlives: true, DialContext: Dial(internalHosts),
		TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12},
	}
}

// Dial refuses an internal address at connect time, after the lookup, unless
// the host being dialled is one internalHosts lists. That list is what
// McpServer::InternalHosts reads from CONNECTORS__INTERNAL_HOSTS, in the same
// form: names, or name:port for that port alone, split by commas or spaces.
// Rails adds the install's own server, which its operator set too.
func Dial(internalHosts string) func(context.Context, string, string) (net.Conn, error) {
	listed := strings.Fields(strings.ReplaceAll(strings.ToLower(internalHosts), ",", " "))
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		dialer := &net.Dialer{Timeout: 10 * time.Second, Control: refuseInternal}
		if host, at, err := net.SplitHostPort(address); err == nil && includes(listed, strings.ToLower(host), at) {
			dialer.Control = nil
		}
		return dialer.DialContext(ctx, network, address)
	}
}

func includes(listed []string, host, at string) bool {
	for _, entry := range listed {
		name, only, ported := strings.Cut(entry, ":")
		if name != "" && name == host && (!ported || port.MatchString(only) && number(only) == number(at)) {
			return true
		}
	}
	return false
}

// As Ruby's to_i reads a listed port, so 0443 is 443.
func number(digits string) int {
	n, _ := strconv.Atoi(digits)
	return n
}

// Called with the resolved address just before each connection is made.
func refuseInternal(_, address string, _ syscall.RawConn) error {
	at, err := netip.ParseAddrPort(address)
	if err != nil || inside(at.Addr()) {
		return fmt.Errorf("%s is on this server or its private network", address)
	}
	return nil
}
