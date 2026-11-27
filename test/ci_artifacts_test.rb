require "test_helper"
require "yaml"

# When CI fails on GitHub, what the failed browser tests saw is uploaded.
# Gitea keeps nothing: it takes upload-artifact v3 only, v4 and later refuse
# any server but GitHub's (CI run 8893), and GitHub fails any job using v3.
class CiArtifactsTest < ActiveSupport::TestCase
  test "a failed job on GitHub uploads tmp/screenshots with a current upload-artifact" do
    steps = YAML.load_file(Rails.root.join(".github/workflows/ci.yml")).dig("jobs", "ci", "steps")
    uploads = steps.select { it["uses"].to_s.start_with?("actions/upload-artifact@") }

    assert_equal 1, uploads.size
    github = uploads.first
    assert_equal "failure() && github.server_url == 'https://github.com'", github["if"]
    assert_operator github["uses"][/@v(\d+)/, 1].to_i, :>=, 4, "GitHub has dropped v3"
    assert_equal "${{ github.workspace }}/tmp/screenshots", github.dig("with", "path")
    assert_equal "warn", github.dig("with", "if-no-files-found"), "a failure that saved nothing says so"
  end
end
