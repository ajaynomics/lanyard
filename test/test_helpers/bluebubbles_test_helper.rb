# The install's BlueBubbles settings for a test, and BlueBubbles itself as
# WebMock stubs over a few made-up chats: nothing reaches a Mac.
module BluebubblesTestHelper
  BLUEBUBBLES = "http://mac.example.com:1234"
  MAYA = "iMessage;-;+14165550199"
  FAMILY = "iMessage;+;chat123456"
  PHOTO = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"

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
  # BlueBubbles 1.9.9's answer when both its scripts fail: only the
  # fallback's osascript error comes back, after the command it ran.
  def send_error(stderr)
    { status: 500, body: { status: 500, message: "Message Send Error",
      error: { type: "iMessage Error", message: "Command failed: osascript -e \"tell application \\\"Messages\\\"\"\n#{stderr}\n" } }.to_json }
  end

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
      .to_return { (messages.respond_to?(:call) ? messages.call : messages).then { json(data: it, metadata: { total: it.size }) } }
    stub_request(:post, "#{BLUEBUBBLES}/api/v1/message/text").with(query: { password: "synthetic-mac-password" }).to_return do |request|
      sends << JSON.parse(request.body)
      answer = send.respond_to?(:call) ? send.call(sends.last) : send
      answer.is_a?(Hash) && answer.key?(:status) ? answer : json(status: 200, data: answer || { guid: "sent-#{sends.size}", isFromMe: true, error: 0, isDelivered: true })
    end
    sends
  end

  # BlueBubbles as in the case of #86: it takes each text into the chat, then
  # gives no answer before the app stops waiting, as if it hung. The chat
  # lists what it took, newest first, from `listed_after` on: the Mac's
  # database may lag. The texts it took.
  def bluebubbles_taking_then_hanging(listed_after: 0.seconds)
    taken = []
    listed = -> { taken.reject { it[:listed_at].after?(Time.current) }.reverse.map { bluebubbles_message(it[:text], from_me: true, guid: it[:guid], at: it[:at]) } }
    stub_bluebubbles(messages: listed, send: ->(body) {
      taken << { text: body["message"], guid: "taken-#{taken.size + 1}", at: Time.current.to_i * 1000, listed_at: Time.current + listed_after }
      raise Net::ReadTimeout
    })
    taken
  end

  # One attachment, PHOTO unless named: its name, type and size, and its bytes.
  def stub_bluebubbles_attachment(bytes, guid: PHOTO, name: "IMG_0001.HEIC", type: "image/heic", size: bytes.bytesize)
    stub_request(:get, "#{BLUEBUBBLES}/api/v1/attachment/#{guid}").with(query: { password: "synthetic-mac-password" })
      .to_return(json(status: 200, data: { guid: guid, transferName: name, mimeType: type, totalBytes: size }))
    stub_request(:get, "#{BLUEBUBBLES}/api/v1/attachment/#{guid}/download").with(query: { password: "synthetic-mac-password" })
      .to_return(status: 200, body: bytes, headers: { "Content-Type" => type })
  end

  def bluebubbles_message(text, from_me: false, guid: SecureRandom.hex(4), delivered: from_me, address: "+14165550199", at: 1_762_700_000_000)
    { guid: guid, text: text, isFromMe: from_me, handle: (from_me ? nil : { address: address }), dateCreated: at,
      isDelivered: delivered, error: 0, attachments: [] }
  end

  private
    def json(body) = { status: 200, body: body.to_json, headers: { "Content-Type" => "application/json" } }
end
