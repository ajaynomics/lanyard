#!/bin/sh
set -eu
browser=$(id -u browser)
hold=$(id -u hold)

# Never open a window between replacement of an old guard and the new one.
# Replies from another user on the proxy port are dropped too: after proxy
# death, an unprivileged process can grab the port but cannot answer on it.
nft -f - <<RULES
add table inet browser_hold
flush table inet browser_hold
table inet browser_hold {
  counter blocked_dns_quic {}
  counter blocked_browser {}
  chain output {
    type filter hook output priority filter; policy accept;
    meta skuid $hold oifname "lo" ip saddr 127.0.0.1 tcp sport 18181 accept
    oifname "lo" ip saddr 127.0.0.1 tcp sport 18181 drop
    meta skuid $browser oifname "lo" ip daddr 127.0.0.1 tcp dport 18181 accept
    oifname "lo" ip daddr 127.0.0.1 tcp dport 18181 drop
    meta skuid $browser udp dport { 53, 443 } counter name blocked_dns_quic drop
    meta skuid $browser counter name blocked_browser drop
  }
}
RULES
