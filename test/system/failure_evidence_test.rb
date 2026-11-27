require "application_system_test_case"

# A failed browser test keeps its picture, its page and what the page's
# console said in tmp/screenshots, which CI uploads when the job fails.
class FailureEvidenceTest < ApplicationSystemTestCase
  test "the page and its console are saved beside the picture" do
    visit sign_in_path
    page.execute_script("console.warn('failure-evidence-marker')")
    send(:save_failure_evidence)

    base = send(:absolute_path)
    assert_match "failure-evidence-marker", File.read("#{base}.console.log")
    assert_match "<html", File.read("#{base}.html")
  ensure
    FileUtils.rm_f([ "#{base}.console.log", "#{base}.html" ]) if base
  end

  # The whole of log/test.log was tens of megabytes (CI run 10181): a failure
  # keeps only its own test's part, which says what the server and the cable did.
  test "the test's own part of the server log is saved beside the picture" do
    visit sign_in_path
    Rails.logger.info("failure-evidence-log-marker")
    send(:save_test_log)

    base = send(:absolute_path)
    log = File.read("#{base}.log")
    assert_match "failure-evidence-log-marker", log
    assert_match "GET \"/sign_in\"", log
  ensure
    FileUtils.rm_f("#{base}.log") if base
  end
end
