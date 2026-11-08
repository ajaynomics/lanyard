# A person names their connector's server, and Rails calls it from inside the
# server's network, so a public name that resolves to this machine or the
# private network would reach what the person can't (McpServer#url_is_https
# stops only names and literal addresses). The name is resolved once, every
# address it gives must be public, and the request goes to that address
# (Net::HTTP#ipaddr) with the name kept for TLS and the Host header: a second
# lookup, which a rebinding server could answer differently, never happens.
# Every request a connector makes passes through here, the OAuth discovery,
# registration and token requests included.
module McpServer::Address
  class Refused < Faraday::ConnectionFailed; end

  # Swapped in tests, which reach no DNS.
  singleton_class.attr_accessor :resolver
  self.resolver = ->(host) { Addrinfo.getaddrinfo(host, nil, nil, :STREAM).map(&:ip_address).uniq }

  class << self
    # For a Faraday connection's builder: every request it makes is pinned.
    def pin(faraday)
      faraday.adapter(:net_http) { |http| http.ipaddr = public_address(http.address) }
    end

    def public_address(host)
      addresses = resolver.call(host.delete("[]"))
      raise Refused, "#{host} has no address" if addresses.empty?
      raise Refused, "#{host} is on this server or its private network" if addresses.any? { internal?(it) }
      addresses.first
    rescue SocketError => failure
      raise Refused, "#{host} has no address: #{failure.message}"
    end

    def internal?(address)
      address = IPAddr.new(address).then { it.ipv4_mapped? || it.ipv4_compat? ? it.native : it }
      address.loopback? || address.private? || address.link_local? || address.to_i.zero? ||
        SHARED.any? { it.include?(address) }
    rescue IPAddr::InvalidAddressError
      true
    end
  end

  # Carrier-grade NAT (RFC 6598) and "this network" (0.0.0.0/8) reach inside
  # as surely as 10/8, and IPAddr#private? knows neither.
  SHARED = [ IPAddr.new("100.64.0.0/10"), IPAddr.new("0.0.0.0/8") ].freeze
end
