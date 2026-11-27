require "test_helper"
require_relative "../test_helpers/agent_test_helper"
require_relative "../test_helpers/email_test_helper"

class EmailBodyFormatTest < ActiveSupport::TestCase
  include AgentTestHelper, EmailTestHelper

  Gmail = DurableAssistants::Google::Gmail
  GMAIL_URL = DurableAssistants::Google::GMAIL
  OPENING = "First paragraph with enough words to run beyond the column where a plain-text composer might wrap it.".freeze
  BODY = ("#{OPENING}  \n\nAt the café: <img src=x onerror=alert(1)> & tea.\r\n\r\n" \
    "- One  \n- Two\r\n\r\n-- \nAvery\n\n> Earlier paragraph.\r\n>\r\n> Another paragraph.\n" \
    ">> Nested <em>as text</em> & café.\r\n> > Still nested.\n> Back at one.\r\nThe score is 5 > 3.\n" \
    ">5 without a quote separator.\n> Last quote.\nFinal answer.\n\n").freeze
  FIELDS = { to: [ "reader@example.com" ], subject: "Trip", body: BODY }.freeze

  test "SMTP send_email encodes both body formats for a message and a reply" do
    with_setting(:mail, :domain, "agents.example") do
      agent = create_user.agents.sole
      message = Mail.new(AgentMailer.message_from(agent, **FIELDS).encoded)
      reply = Mail.new(AgentMailer.message_from(agent, **FIELDS.merge(subject: "Re: Trip"),
        in_reply_to: "previous@example.com", files: [ [ "plan.txt", "A plan" ] ]).encoded)

      assert_equal [ "previous@example.com", "previous@example.com" ], [ reply.in_reply_to, reply.references ]
      assert_equal [ "plan.txt" ], reply.attachments.map(&:filename)
      assert_body_formats message
      assert_body_formats reply
    end
  end

  test "Gmail create_draft encodes both body formats in the raw message" do
    created = capture_request(:post, "drafts", message: { id: "m1" }, id: "d1") do
      Gmail.save_draft("synthetic", **FIELDS)
    end

    assert_body_formats parse_raw(created.fetch("message"))
  end

  test "Gmail update_draft replaces both body formats in the raw message" do
    updated = capture_request(:put, "drafts/d1", message: { id: "m2" }, id: "d1") do
      Gmail.save_draft("synthetic", draft_id: "d1", **FIELDS)
    end

    assert_body_formats parse_raw(updated.fetch("message"))
  end

  test "Gmail send_message encodes both body formats for a reply with attachments" do
    replying = { "payload" => { "headers" => [ { "name" => "Subject", "value" => "Trip" },
      { "name" => "Message-ID", "value" => "<previous@example.com>" } ] } }
    sent = capture_request(:post, "messages/send", id: "m1", threadId: "t1") do
      Gmail.send_message("synthetic", **FIELDS.except(:subject), thread_id: "t1", replying: replying, files: [ [ "plan.txt", "A plan" ] ])
    end

    assert_equal "t1", sent.fetch("threadId")
    mail = parse_raw(sent)
    assert_equal [ "Re: Trip", "previous@example.com", "previous@example.com" ], [ mail.subject, mail.in_reply_to, mail.references ]
    assert_equal [ "plan.txt" ], mail.attachments.map(&:filename)
    assert_body_formats mail
  end

  test "Gmail send_draft previews the stored plain text and sends by id without recomposing" do
    saved = capture_request(:post, "drafts", id: "d1") { Gmail.save_draft("synthetic", **FIELDS) }
    stored = saved.fetch("message")
    stub_request(:get, "#{GMAIL_URL}/drafts/d1?format=raw").to_return(json(message: stored))
    assert_equal BODY.b, Gmail.draft_preview("synthetic", draft_id: "d1").fetch("body").b

    sent = capture_request(:post, "drafts/send", id: "m1") { Gmail.send_draft("synthetic", draft_id: "d1") }
    assert_equal({ "id" => "d1" }, sent)
  end

  private
    def assert_body_formats(mail)
      plain = mail.multipart? ? mail.text_part&.decoded : mail.decoded
      assert_equal normalized(BODY), normalized(plain.to_s), "plain text must not gain or lose lines"

      alternative = mail.attachments.any? ? mail.parts.first : mail
      assert_equal "multipart/alternative", alternative.mime_type, "the message has no rich-text alternative"
      assert_equal %w[ text/plain text/html ], alternative.parts.map(&:mime_type)
      assert_equal BODY.b, mail.text_part.decoded.b, "the decoded plain part must retain every byte"

      fragment = Nokogiri::HTML5.fragment(mail.html_part.decoded.force_encoding(Encoding::UTF_8))
      assert_equal %w[ p p p p blockquote p blockquote p ], fragment.element_children.map(&:name)
      outer, last = fragment.element_children.select { |element| element.name == "blockquote" }
      assert_equal %w[ p p blockquote p ], outer.element_children.map(&:name)
      assert_equal %w[ p ], outer.at_css("blockquote").element_children.map(&:name)
      assert_equal %w[ p ], last.element_children.map(&:name)
      assert_equal [ OPENING, "At the café: <img src=x onerror=alert(1)> & tea.", "- One  |- Two", "-- |Avery",
        "Earlier paragraph.", "Another paragraph.", "Nested <em>as text</em> & café.|Still nested.", "Back at one.",
        "The score is 5 > 3.|>5 without a quote separator.", "Last quote.", "Final answer." ], fragment.css("p").map { |paragraph|
          paragraph.css("br").each { it.replace("|") }
          paragraph.text.delete("\r\n").rstrip
        }
      assert_empty fragment.css("img, em"), "body text must never be interpreted as HTML"
    end

    def normalized(text) = text.dup.force_encoding(Encoding::UTF_8).gsub("\r\n", "\n")

    def parse_raw(message) = Mail.new(Base64.urlsafe_decode64(message.fetch("raw")))

    def json(payload) = { headers: { "Content-Type" => "application/json" }, body: payload.to_json }

    def capture_request(method, path, **response)
      requests = []
      stub_request(method, "#{GMAIL_URL}/#{path}").with { |request| requests << JSON.parse(request.body) }.to_return(json(response))
      yield
      requests.sole
    end
end
