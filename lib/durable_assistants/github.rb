require "net/http"
require "uri"

module DurableAssistants
  # GitHub's public repositories, read without signing in (docs/skills.md): a
  # commit's SHA, its tree, and a file's bytes at that commit. Each answer is
  # read only up to its limit, and each request gives up after TIMEOUT.
  module Github
    API = "https://api.github.com"
    RAW = "https://raw.githubusercontent.com"
    HOSTS = [ URI(API).host, URI(RAW).host ].freeze
    TIMEOUT = 10 # seconds
    # A large repository's whole tree, listed in one answer.
    TREE_BYTES = 20.megabytes
    REDIRECTS = 2

    class Error < StandardError; end
    class NotFound < Error; end

    # The commit a branch, tag or SHA names; HEAD is the default branch.
    def self.commit(repo, ref)
      sha = get("#{API}/repos/#{path(repo)}/commits/#{path(ref)}", accept: "application/vnd.github.sha", limit: 100).strip
      sha.match?(/\A\h{40}\z/) ? sha : raise(Error, "GitHub answered with something that isn't a commit.")
    end

    # Every file in the commit: { "tree" => [{ "path", "mode", "type", "size", "sha" }], "truncated" }.
    def self.tree(repo, sha)
      JSON.parse(get("#{API}/repos/#{path(repo)}/git/trees/#{path(sha)}?recursive=1", accept: "application/vnd.github+json", limit: TREE_BYTES))
    rescue JSON::ParserError
      raise Error, "GitHub's list of files couldn't be read."
    end

    def self.file(repo, sha, file, limit:) = get("#{RAW}/#{path(repo)}/#{path(sha)}/#{path(file)}", limit: limit)

    # Each step escaped, and none of `.` or `..`, so a name can't climb to
    # another of GitHub's paths.
    def self.path(text)
      steps = text.to_s.split("/", -1)
      raise NotFound, "GitHub has no such thing." if steps.empty? || steps.any? { it.in?([ "", ".", ".." ]) }
      steps.map { ERB::Util.url_encode(it) }.join("/")
    end

    def self.get(url, limit:, accept: nil, redirects: REDIRECTS)
      uri = URI(url)
      request = Net::HTTP::Get.new(uri, { "User-Agent" => "durable-assistants", "Accept" => accept }.compact)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) do |http|
        http.request(request) do |response|
          case response
          when Net::HTTPSuccess then return read(response, limit)
          when Net::HTTPRedirection
            location = URI.join(url, response["location"].to_s)
            raise Error, "GitHub sent the request somewhere else." unless redirects.positive? && location.scheme == "https" && HOSTS.include?(location.host)
            return get(location.to_s, limit: limit, accept: accept, redirects: redirects - 1)
          when Net::HTTPNotFound, Net::HTTPUnprocessableEntity then raise NotFound, "GitHub has no such thing."
          when Net::HTTPForbidden, Net::HTTPTooManyRequests
            raise Error, "GitHub is limiting requests from this server for now. Try again in a while." if response["x-ratelimit-remaining"] == "0" || response.is_a?(Net::HTTPTooManyRequests)
            raise NotFound, "GitHub won't show it: it may be private."
          else raise Error, "GitHub answered HTTP #{response.code}."
          end
        end
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError => error
      raise Error, "Couldn't reach GitHub (#{error.class.name.demodulize})."
    end

    def self.read(response, limit)
      raise Error, "GitHub's answer is larger than #{limit} bytes." if response["content-length"].to_i > limit
      body = +"".b
      response.read_body do |chunk|
        body << chunk
        raise Error, "GitHub's answer is larger than #{limit} bytes." if body.bytesize > limit
      end
      body
    end
  end
end
