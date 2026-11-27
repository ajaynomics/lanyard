require "test_helper"
require "net/imap"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"
require_relative "../test_helpers/passbolt_test_helper"

# Mail and texts reach an agent in seconds (#262): a connection held open on
# each box with IMAP IDLE (RFC 2177) enqueues that box's own fetch the moment
# its server says a message landed, rather than waiting for the minute's read
# (EmailFetchJob). Net::IMAP is the one stand-in for the servers, the fake
# `passbolt` command for the vault and WebMock for the sidecar; the idler, the
# fetch, the delivery and the thread run for real.
class MailIdlerTest < ActiveJob::TestCase
  include AgentTestHelper
  include EmailTestHelper
  include PassboltTestHelper

  SMTP = "smtp.mail.example.com"
  IMAP = "imap.mail.example.com"
  # A watcher waits on its server; a test should not wait on a watcher.
  PATIENCE = 10

  # A box as Net::IMAP shows it, which both holds IDLE and answers the fetch
  # that follows. `announce` is the server saying a message landed.
  class FakeBox
    attr_reader :logins, :idles, :searches
    attr_accessor :refuse_idle

    def initialize(messages = {}, validity: 7)
      @messages, @validity = messages, validity
      @logins, @idles, @searches = [], [], []
      @idling, @mutex = ConditionVariable.new, Mutex.new
    end

    def login(user, password) = @mutex.synchronize { @logins << [ user, password ] }
    def capable?(name) = name.to_s.casecmp("IDLE").zero?
    def examine(_folder) = nil
    # Ends an IDLE in progress, as a real connection closing does.
    def disconnect = @mutex.synchronize { @handler = nil; idle_done }

    # Waits as a server at IDLE does, until the test announces a message or
    # the watcher's own limit passes.
    def idle(timeout, &handler)
      @mutex.synchronize do
        @idles << timeout
        raise refuse_idle if refuse_idle
        @handler, @done = handler, false
        @idling.broadcast
        over = Time.current + timeout
        @idling.wait(@mutex, [ over - Time.current, 0 ].max) until @done || Time.current >= over
        @handler = nil
      end
    end

    def idle_done = (@done = true).tap { @idling.broadcast }

    # The server says the folder holds a message it had not announced; says
    # how many times it has been asked for IDLE by then.
    def announce(uid, raw, at: Time.current)
      @mutex.synchronize do
        @messages[uid] = [ raw, at ]
        @idling.wait(@mutex, PATIENCE) until @handler
        @handler.call(Net::IMAP::UntaggedResponse.new("EXISTS", @messages.size, nil))
        @idles.size
      end
    end

    def idled? = @mutex.synchronize { @idles.any? }

    def responses(name)
      yield({ "UIDVALIDITY" => [ @validity ], "UIDNEXT" => [ @messages.keys.max.to_i + 1 ] }.fetch(name, []))
    end

    def uid_search(keys)
      @searches << keys
      case keys
      in [ "UID", range ] then @messages.keys.select { it >= range.to_i }.presence || [ @messages.keys.max ].compact
      in [ "SINCE", Date => day ] then @messages.select { |_, (_, at)| at.to_date >= day }.keys
      in [ "ALL" ] then @messages.keys
      end
    end

    def uid_fetch(uids, part)
      uids.map do |uid|
        raw, at = @messages.fetch(uid)
        Struct.new(:attr).new(part == "INTERNALDATE" ? { "UID" => uid, "INTERNALDATE" => Net::IMAP.encode_time(at).delete('"') } :
          { "UID" => uid, "BODY[]" => raw })
      end
    end
  end

  setup do
    install_sidecar_settings
    install_email_settings
    @original_new = Net::IMAP.method(:new)
    @original_cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
    @boxes = Hash.new { |boxes, host| boxes[host] = FakeBox.new }
    boxes = @boxes
    Net::IMAP.define_singleton_method(:new) { |host, **| boxes[host] }

    @alice = create_user(name: "Alice")
    @travel = name_agent(@alice.agents.sole, "Travel")
    Agent.where(id: @travel.id).update_all(email_name: "travel")
    @travel.reload

    @submissions = Queue.new
    stub_request(:post, "#{SIDECAR}/v1/conversations").to_return(status: 201, body: { id: "c-thread" }.to_json)
    stub_request(:post, %r{\A#{SIDECAR}/v1/conversations/c-thread/submissions\z}).to_return { |request|
      @submissions << JSON.parse(request.body)
      { status: 202, body: { id: @submissions.size, status: "queued" }.to_json } }
    stub_request(:get, %r{\A#{SIDECAR}/v1/conversations/c-thread/entries}).to_return(body: { entries: [], cursor: nil, more: false }.to_json)
  end

  teardown do
    @idler&.stop
    Net::IMAP.define_singleton_method(:new, @original_new)
    Rails.cache = @original_cache
    remove_fake_passbolt if @fake_passbolt
    remove_email_settings
    remove_sidecar_settings
  end

  test "a message the install's box takes between two reads reaches the thread in seconds, with no read of the minute" do
    box = @boxes["imap.agents.example"]
    watch

    landed = Time.current
    perform_enqueued_jobs do
      assert_equal "email:#{@travel.id}:now@example.com", land(box, 4, raw(to: "travel@agents.example", id: "now@example.com", subject: "Gate change"))
    end
    assert_operator Time.current - landed, :<, 5, "the message took longer than five seconds to reach the thread"
    assert_equal [ [ "catchall", "synthetic" ] ], box.logins.first(1), "watched with the install's own sign-in"
  end

  test "a text takes the same path, in seconds" do
    box = @boxes["imap.agents.example"]
    watch

    landed = Time.current
    perform_enqueued_jobs do
      assert_equal "email:#{@travel.id}:sms@voip.ms", land(box, 4, raw(from: "sms@voip.ms", to: "travel@agents.example", id: "sms@voip.ms",
        subject: "Message received from number 9995550188 to number 9995550123 [#1]", body: "Running late."))
    end
    assert_operator Time.current - landed, :<, 5, "the text took longer than five seconds to reach the thread"
  end

  test "an agent's own inbox is watched too, and what lands there reaches its thread" do
    install_fake_passbolt(name: "Agent mailbox", uri: SMTP)
    @fake_passbolt = true
    @travel.create_mail_account!(address: "desk@mail.example.com", smtp_host: SMTP, imap_host: IMAP,
      vault_entry: "Agent mailbox", inbox_validity: 7, inbox_last_uid: 2, inbox_read_at: 1.hour.ago)
    box = @boxes[IMAP]
    watch

    perform_enqueued_jobs do
      assert_equal "email:#{@travel.id}:own@example.com", land(box, 3, raw(to: "desk@mail.example.com", id: "own@example.com"))
    end
    assert_equal [ [ "maya", PassboltTestHelper::PASSWORD ] ], box.logins.first(1), "watched with the vault entry, read as the agent"
  end

  test "a dropped connection is made again, and what landed while it was down still arrives" do
    box = @boxes["imap.agents.example"]
    box.refuse_idle = Net::IMAP::Error.new("connection closed")
    watch(backoff: 0.05)
    wait_until("the watcher to try again") { box.idles.size >= 2 }

    box.refuse_idle = nil
    perform_enqueued_jobs do
      wait_until("the watcher to hold the connection again") { box.idles.size >= 3 }
      assert_equal "email:#{@travel.id}:back@example.com", land(box, 4, raw(to: "travel@agents.example", id: "back@example.com"))
    end
    assert_operator box.logins.size, :>=, 2, "it signed in again rather than sitting on a dead connection"
  end

  test "one connection asks for IDLE again before the server's own timeout, under the RFC's half hour" do
    box = @boxes["imap.agents.example"]
    watch(idle_for: 0.05)
    wait_until("a second IDLE on the same connection") { box.idles.size >= 2 }

    assert_equal 1, box.logins.size, "it held one connection rather than making a new one"
    assert_operator MailIdler::Watch::IDLE_FOR, :<, 29.minutes, "RFC 2177 asks for IDLE again at least every 29 minutes"
  end

  test "a box added is watched, and one taken away is let go" do
    install_fake_passbolt(name: "Agent mailbox", uri: SMTP)
    @fake_passbolt = true
    watch(refresh: 0.05)
    assert_equal [ "install" ], @idler.watching

    account = @travel.create_mail_account!(address: "desk@mail.example.com", smtp_host: SMTP, imap_host: IMAP,
      vault_entry: "Agent mailbox", inbox_validity: 7, inbox_last_uid: 2, inbox_read_at: 1.hour.ago)
    wait_until("the new box to be watched") { @idler.watching.include?("account:#{account.id}") }
    wait_until("the account's own server to be asked to hold the connection") { @boxes[IMAP].idled? }

    account.destroy!
    wait_until("the box taken away to be let go") { @idler.watching == [ "install" ] }
  end

  test "the minute's read goes on, so a server without IDLE is no more than a minute behind" do
    box = @boxes["imap.agents.example"]
    box.define_singleton_method(:capable?) { |_| false }
    watch

    perform_enqueued_jobs do
      box.instance_variable_get(:@messages)[4] = [ raw(to: "travel@agents.example", id: "poll@example.com"), Time.current ]
      EmailFetchJob.perform_now
      assert_equal "email:#{@travel.id}:poll@example.com", @submissions.pop(timeout: PATIENCE)["requestId"]
    end
  end

  private
    def watch(**settings)
      @idler = MailIdler.new(**settings)
      @running = Thread.new { @idler.run }
      wait_until("the first box to be watched") { @idler.watching.any? }
      @idler
    end

    # A message lands, and the watcher runs its fetch and delivery (inline,
    # under perform_enqueued_jobs) through to the thread's pull, waiting on the
    # server again only once all of it is done. The submission alone is not the
    # end: a pull still running when the test ends reaches the sidecar after
    # WebMock's reset, and is counted in whichever test runs next.
    def land(box, uid, message)
      asked = box.announce(uid, message)
      submission = @submissions.pop(timeout: PATIENCE)
      wait_until("the watcher to finish delivering and wait again") { box.idles.size > asked }
      assert_requested :get, %r{\A#{SIDECAR}/v1/conversations/c-thread/entries}, times: 1
      submission&.fetch("requestId")
    end

    def wait_until(what, within: PATIENCE)
      deadline = Time.current + within
      sleep 0.01 until yield || Time.current > deadline
      assert yield, "waited #{within} seconds for #{what}"
    end

    def raw(from: "Maya <maya@example.com>", to: "travel@agents.example", id: "m@example.com", subject: "Lisbon", body: "Friday?")
      Mail.new(from: from, to: to, subject: subject, body: body, message_id: "<#{id}>", date: Time.current).to_s
    end
end
