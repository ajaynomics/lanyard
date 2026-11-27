require "test_helper"
require "yaml"

class CiTimeoutsTest < ActiveSupport::TestCase
  test "bin/ci has a step timeout Gitea enforces" do
    step = steps_for("ci").find { |step| step["run"] == "bin/ci" }
    assert_equal 55, step&.fetch("timeout-minutes", nil)
  end

  test "publish builds and checks have step timeouts Gitea enforces" do
    %w[bin/check-computer-image bin/check-hold-proof].each do |command|
      step = steps_for("publish").find { |step| step["run"].to_s.include?(command) }
      assert_equal 25, step&.fetch("timeout-minutes", nil), command
    end
  end

  private
    def steps_for(job)
      YAML.safe_load_file(Rails.root.join(".github/workflows/ci.yml")).fetch("jobs").fetch(job).fetch("steps")
    end
end
