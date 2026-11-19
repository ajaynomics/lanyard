require "test_helper"

# GitHub's public API and raw files, read without signing in: each answer
# capped, each request timed out, and only GitHub's own hosts followed.
class GithubTest < ActiveSupport::TestCase
  REPO = "acme/skills".freeze
  SHA = "1111111111111111111111111111111111111111".freeze

  test "a commit's SHA, a tree and a file" do
    stub_request(:get, "https://api.github.com/repos/#{REPO}/commits/feature/new").with(headers: { "Accept" => "application/vnd.github.sha" }).to_return(body: SHA)
    stub_request(:get, "https://api.github.com/repos/#{REPO}/git/trees/#{SHA}?recursive=1").to_return(body: { tree: [ { path: "SKILL.md" } ] }.to_json)
    stub_request(:get, "https://raw.githubusercontent.com/#{REPO}/#{SHA}/a%20b/SKILL.md").to_return(body: "hi")

    assert_equal SHA, DurableAssistants::Github.commit(REPO, "feature/new")
    assert_equal "SKILL.md", DurableAssistants::Github.tree(REPO, SHA)["tree"].sole["path"]
    assert_equal "hi", DurableAssistants::Github.file(REPO, SHA, "a b/SKILL.md", limit: 10)
  end

  test "an answer over its limit, a redirect elsewhere, an unreachable GitHub and a missing thing are errors" do
    stub_request(:get, "https://raw.githubusercontent.com/#{REPO}/#{SHA}/big").to_return(body: "x" * 11)
    assert_raises(DurableAssistants::Github::Error) { DurableAssistants::Github.file(REPO, SHA, "big", limit: 10) }

    stub_request(:get, "https://api.github.com/repos/#{REPO}/commits/HEAD").to_return(status: 301, headers: { "Location" => "https://evil.example/x" })
    assert_match(/somewhere else/, assert_raises(DurableAssistants::Github::Error) { DurableAssistants::Github.commit(REPO, "HEAD") }.message)

    stub_request(:get, "https://api.github.com/repos/acme/moved/commits/HEAD").to_return(status: 301, headers: { "Location" => "https://api.github.com/repositories/7/commits/HEAD" })
    stub_request(:get, "https://api.github.com/repositories/7/commits/HEAD").to_return(body: SHA)
    assert_equal SHA, DurableAssistants::Github.commit("acme/moved", "HEAD"), "a renamed repository is followed on GitHub"

    stub_request(:get, "https://api.github.com/repos/acme/slow/commits/HEAD").to_timeout
    assert_match(/Couldn't reach GitHub/, assert_raises(DurableAssistants::Github::Error) { DurableAssistants::Github.commit("acme/slow", "HEAD") }.message)

    stub_request(:get, "https://api.github.com/repos/acme/private/commits/HEAD").to_return(status: 404)
    assert_raises(DurableAssistants::Github::NotFound) { DurableAssistants::Github.commit("acme/private", "HEAD") }
  end
  test "a repository, ref or file named with . or .. never leaves its own path on GitHub" do
    assert_raises(DurableAssistants::Github::NotFound) { DurableAssistants::Github.commit("acme/..", "HEAD") }
    assert_raises(DurableAssistants::Github::NotFound) { DurableAssistants::Github.commit(REPO, "main/../../../users/x") }
    assert_raises(DurableAssistants::Github::NotFound) { DurableAssistants::Github.file(REPO, SHA, "../other/SKILL.md", limit: 10) }
    assert_not_requested :any, /github/
  end
end
