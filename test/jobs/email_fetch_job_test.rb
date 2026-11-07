require "test_helper"
require "net/imap"
require_relative "../test_helpers/email_test_helper"

class EmailFetchJobTest < ActiveJob::TestCase
  include EmailTestHelper

  # A catch-all box as Net::IMAP shows it: numbered messages and its UIDVALIDITY.
  class FakeBox
    attr_reader :searches, :logins

    def initialize(messages, validity) = (@messages, @validity, @searches, @logins = messages, validity, [], [])
    def login(user, password) = @logins << [ user, password ]
    def examine(_mailbox) = nil
    def responses(name) = yield(name == "UIDVALIDITY" ? [ @validity ] : [])
    def disconnect = nil

    # "n:*" always includes the newest message, even below n, as IMAP does.
    def uid_search(keys)
      @searches << keys
      from = keys.last.to_i
      @messages.keys.select { it >= from }.presence || [ @messages.keys.max ].compact
    end

    def uid_fetch(uids, _part) = uids.map { Struct.new(:attr).new({ "UID" => it, "BODY[]" => @messages.fetch(it) }) }
  end

  setup do
    install_email_settings
    @original_new = Net::IMAP.method(:new)
    # The test environment's cache keeps nothing; production's does.
    @original_cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Net::IMAP.define_singleton_method(:new, @original_new)
    remove_email_settings
    Rails.cache = @original_cache
  end

  test "new mail goes to Action Mailbox once; the next run starts after the last message, and a renumbered box from the start" do
    box = open_box({ 3 => raw_mail("one"), 5 => raw_mail("two") }, validity: 7)
    assert_difference -> { ActionMailbox::InboundEmail.count }, 2 do
      EmailFetchJob.perform_now
    end
    assert_equal [ [ "catchall", "synthetic" ] ], box.logins

    assert_no_difference -> { ActionMailbox::InboundEmail.count } do
      EmailFetchJob.perform_now
    end
    assert_equal [ "UID", "6:*" ], box.searches.last

    box = open_box({ 1 => raw_mail("one"), 2 => raw_mail("three") }, validity: 8)
    assert_difference -> { ActionMailbox::InboundEmail.count }, 1 do
      EmailFetchJob.perform_now
    end
    assert_equal [ "UID", "1:*" ], box.searches.last
  end

  test "without a mailbox to read it does nothing" do
    with_setting(:mail, :imap_address, nil) do
      Net::IMAP.define_singleton_method(:new) { |*| raise "no connection expected" }
      assert_no_difference(-> { ActionMailbox::InboundEmail.count }) { EmailFetchJob.perform_now }
    end
  end

  private
    def open_box(messages, validity:)
      FakeBox.new(messages, validity).tap { |box| Net::IMAP.define_singleton_method(:new) { |*, **| box } }
    end

    def raw_mail(id) = Mail.new(from: "a@example.com", to: "travel@agents.example", subject: id, body: id, message_id: "<#{id}@example.com>", date: Time.utc(2026, 11, 8)).to_s
end
