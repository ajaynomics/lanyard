require "test_helper"
require_relative "../test_helpers/agent_test_helper"

class PromptTest < ActiveSupport::TestCase
  include AgentTestHelper

  setup { @bot = create_user.bots.sole }

  test "arguments go in pi's placeholders" do
    expand = ->(body, arguments) { @bot.prompts.new(name: "p", body: body).expand(arguments) }

    assert_equal "Review a.rb for speed", expand.("Review $1 for $2", "a.rb speed")
    assert_equal "All: a b c", expand.("All: $@", "a b c")
    assert_equal "All: a b c", expand.("All: $ARGUMENTS", "a b c")
    assert_equal "From two: b c", expand.("From two: ${@:2}", "a b c")
    assert_equal "Two from two: b c", expand.("Two from two: ${@:2:2}", "a b c d")
    assert_equal "Zero counts as one: a b", expand.("Zero counts as one: ${@:0}", "a b")
    assert_equal "Default: none", expand.("Default: ${1:-none}", "")
  end

  test "quoted words stay together and lose their quotes, as pi splits them" do
    prompt = @bot.prompts.new(name: "p", body: "[$1] [$2] [$3]")

    assert_equal "[a b] [it's] [c]", prompt.expand(%(  "a b"  "it's" c ))
    assert_equal %w[ ab cd ], Prompt.split_arguments(%(a"b" 'c'd))
    assert_equal [], Prompt.split_arguments(%("" ''))
  end

  test "a missing argument is empty, and an argument is never expanded again" do
    prompt = @bot.prompts.new(name: "p", body: "1=$1 2=$2 all=$@")

    assert_equal "1=$2 2= all=$2", prompt.expand("$2")
    assert_equal "1= 2= all=", prompt.expand(nil)
  end

  test "names follow the skill rules, are the bot's own, and never a built-in command" do
    assert @bot.prompts.create(name: "review-code", body: "Review $@").persisted?
    assert_equal "review-it", @bot.prompts.create!(name: " /review-it ", body: "x").name

    [ "Review", "two--hyphens", "-edge", "a b", "x" * 65, "review-code" ].each do |name|
      assert_not @bot.prompts.new(name: name, body: "x").valid?, name
    end
    Prompt::BUILT_IN.each { assert_includes @bot.prompts.new(name: it, body: "x").tap(&:valid?).errors[:name], "is one of the built-in commands" }
  end

  test "a body is required and at most 32 KB, and a bot has at most 32 prompts" do
    assert_not @bot.prompts.new(name: "empty", body: "").valid?
    assert_not @bot.prompts.new(name: "huge", body: "é" * 16_385).valid?
    assert @bot.prompts.new(name: "fits", body: "x" * 32.kilobytes).valid?

    Prompt::LIMIT.times { @bot.prompts.create!(name: "p#{it}", body: "x") }
    assert_match(/already has 32/, @bot.prompts.create(name: "one-more", body: "x").errors.full_messages.to_sentence)
  end

  test "the list's hint is the description, or the body's first line" do
    assert_equal "Checks code", @bot.prompts.new(description: "Checks code", body: "x").hint
    assert_equal "Review this", @bot.prompts.new(body: "\n  Review this\nand more").hint
  end

  test "saving or removing a prompt keeps a revision with it" do
    prompt = nil
    assert_difference -> { @bot.revisions.count } do
      prompt = @bot.prompts.create!(name: "review", body: "Review $1")
    end
    assert_equal [ { "name" => "review", "description" => "", "body" => "Review $1" } ], @bot.revisions.last.prompts

    assert_difference -> { @bot.revisions.count } do
      prompt.destroy!
    end
    assert_empty @bot.revisions.last.prompts
  end
end
