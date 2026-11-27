require "minitest/autorun"
require "yaml"

class RecurringTest < Minitest::Test
  def test_preserves_tool_call_results_by_default
    schedule = YAML.load_file(File.expand_path("../../config/recurring.yml", __dir__), aliases: true).fetch("production")

    assert schedule.values.none? { |task| task["command"] == "Invocation.prune_results" },
      "The default schedule must not clear tool-call results"
  end
end
