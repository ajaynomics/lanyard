require "test_helper"
require "yaml"

# When CI fails, what the failed browser tests saw is uploaded, by an
# upload-artifact the forge running the job accepts.
class CiArtifactsTest < ActiveSupport::TestCase
  test "a failed job uploads tmp/screenshots on Gitea with v3 and on GitHub with a current version" do
    steps = YAML.load_file(Rails.root.join(".github/workflows/ci.yml")).dig("jobs", "ci", "steps")
    uploads = steps.select { it["uses"].to_s.start_with?("actions/upload-artifact@") }

    gitea = uploads.find { it["if"] == "failure() && github.server_url != 'https://github.com'" }
    github = uploads.find { it["if"] == "failure() && github.server_url == 'https://github.com'" }
    assert_equal "actions/upload-artifact@v3", gitea&.dig("uses"), "Gitea refuses v4 and later (CI run 8893)"
    assert_operator github&.dig("uses").to_s[/@v(\d+)/, 1].to_i, :>=, 4, "GitHub has dropped v3"
    [ gitea, github ].each do |step|
      assert_equal "${{ github.workspace }}/tmp/screenshots", step.dig("with", "path")
      assert_equal "warn", step.dig("with", "if-no-files-found"), "a failure that saved nothing says so"
    end
  end
end
