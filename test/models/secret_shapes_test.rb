require "test_helper"
require "open3"

# The shapes and the answers are shared with the sidecar (agent/test/secret-mask.test.mjs):
# one file of patterns, one of cases, and both sides must give the same answer.
class SecretShapesTest < ActiveSupport::TestCase
  FIXTURE = JSON.parse(Rails.root.join("test/fixtures/secret_shapes.json").read)

  FIXTURE.fetch("cases").each_with_index do |example, index|
    test "case #{index}: #{example["input"].lines.first.strip.truncate(60)}" do
      assert_equal example["expected"], SecretShapes.mask(example["input"], app_url: FIXTURE["appUrl"]).text
    end
  end

  test "says how many it masked, and leaves text with none as it was" do
    masked = SecretShapes.mask("API_KEY=fakefakefake01 and sk-ant-api03-FakeExample0000MadeUp1111", app_url: FIXTURE["appUrl"])
    assert_equal 2, masked.count
    assert_equal "[masked 2 secret-shaped values]", masked.note
    assert_equal "[masked 1 secret-shaped value]", SecretShapes.mask("API_KEY=fakefakefake01").note
    assert_equal [ "nothing here", 0 ], SecretShapes.mask("nothing here").then { [ it.text, it.count ] }
  end

  test "the sign-in link is kept only on this install's own address" do
    link = "https://assistants.example.com/sign_in_links/Fake9Sign7In5Link3Token1MadeUp2Value4abcd"
    assert_equal link, SecretShapes.mask(link, app_url: "https://assistants.example.com").text
    assert_match "[masked]", SecretShapes.mask(link, app_url: "https://app.example.com").text
    assert_match "[masked]", SecretShapes.mask(link, app_url: nil).text
  end

  test "every shape is a regular expression in both Ruby and JavaScript, in the subset they share" do
    shapes = JSON.parse(Rails.root.join("config/secret_shapes.json").read)
    assert shapes.any?
    shapes.each do |shape|
      assert_equal %w[ keep name pattern ], (shape.keys - [ "entropy" ]).sort, shape["name"]
      assert_includes [ true, false ], shape["keep"]
      assert_kind_of Regexp, Regexp.new(shape["pattern"])
      # Lookbehind, named groups and inline flags differ between the engines.
      assert_no_match(/\(\?<|\(\?[imx]|\\[AzZhRXK]|\\p\{/, shape["pattern"], shape["name"])
    end
    script = "const shapes = JSON.parse(require('fs').readFileSync(0, 'utf8')); " \
      "for (const shape of shapes) new RegExp(shape.pattern, 'g'); console.log(shapes.length);"
    out, status = Open3.capture2e("node", "-e", script, stdin_data: shapes.to_json)
    assert status.success?, out
    assert_equal shapes.size.to_s, out.strip
  end

  test "a long run of almost-secret text is masked in time" do
    text = "a.b-c_d." * 25_000 + " password=\"" * 5_000 + "Aa1_" * 25_000
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    SecretShapes.mask(text)
    took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert took < 5, "took #{took.round(1)} s"
  end
end
