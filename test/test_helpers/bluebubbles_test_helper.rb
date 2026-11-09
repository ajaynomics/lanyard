# The install's BlueBubbles settings for a test, and BlueBubbles itself as
# WebMock stubs over a few made-up chats: nothing reaches a Mac.
module BluebubblesTestHelper
  BLUEBUBBLES = "http://mac.example.com:1234"
  MAYA = "iMessage;-;+14165550199"
  FAMILY = "iMessage;+;chat123456"

  def install_bluebubbles_settings
    settings = Rails.application.config.x.bluebubbles
    @previous_bluebubbles = settings.dup
    settings.merge!(url: BLUEBUBBLES, password: "synthetic-mac-password")
    @previous_cache, Rails.cache = Rails.cache, ActiveSupport::Cache::MemoryStore.new
  end

  def remove_bluebubbles_settings
    Rails.application.config.x.bluebubbles.replace(@previous_bluebubbles) if @previous_bluebubbles
    Rails.cache = @previous_cache if @previous_cache
  end

  # BlueBubbles with two chats, Maya's and a family group, and `messages` in
  # every chat. Each send is kept, and answered with `send` (a message, or a
  # WebMock response to raise or return instead).
  def stub_bluebubbles(messages: [], send: nil)
    sends = []
    stub_request(:get, "#{BLUEBUBBLES}/api/v1/contact").with(query: { password: "synthetic-mac-password" })
      .to_return(json(data: [ { displayName: "Maya Patel", phoneNumbers: [ { address: "+1 (416) 555-0199" } ], emails: [] },
                              { firstName: "Robin", lastName: "Lee", phoneNumbers: [], emails: [ { address: "robin@example.com" } ] } ]))
    stub_request(:post, "#{BLUEBUBBLES}/api/v1/chat/query").with(query: { password: "synthetic-mac-password" })
      .to_return(json(data: [
        { guid: MAYA, chatIdentifier: "+14165550199", displayName: "", participants: [ { address: "+14165550199" } ],
          lastMessage: { dateCreated: 1_762_700_000_000 } },
        { guid: FAMILY, chatIdentifier: "chat123456", displayName: "Family", participants: [ { address: "+14165550199" }, { address: "robin@example.com" } ],
          lastMessage: { dateCreated: 1_762_600_000_000 } } ]))
    stub_request(:post, "#{BLUEBUBBLES}/api/v1/message/query").with(query: { password: "synthetic-mac-password" })
      .to_return { json(data: messages, metadata: { total: messages.size }) }
    stub_request(:post, "#{BLUEBUBBLES}/api/v1/message/text").with(query: { password: "synthetic-mac-password" }).to_return do |request|
      sends << JSON.parse(request.body)
      answer = send.respond_to?(:call) ? send.call(sends.last) : send
      answer.is_a?(Hash) && answer.key?(:status) ? answer : json(status: 200, data: answer || { guid: "sent-#{sends.size}", isFromMe: true, error: 0, isDelivered: true })
    end
    sends
  end

  def bluebubbles_message(text, from_me: false, guid: SecureRandom.hex(4), delivered: from_me, address: "+14165550199", at: 1_762_700_000_000)
    { guid: guid, text: text, isFromMe: from_me, handle: (from_me ? nil : { address: address }), dateCreated: at,
      isDelivered: delivered, error: 0, attachments: [] }
  end

  private
    def json(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
end
