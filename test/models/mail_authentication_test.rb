require "test_helper"

class MailAuthenticationTest < ActiveSupport::TestCase
  RECEIVE = "Received: from relay.example.net by mx.example.com; Thu, 19 Nov 2026 14:29:00 +0000"

  test "DKIM pass aligns with the From domain or with a subdomain at a label boundary" do
    assert verified?("mx.example.com; dkim=pass header.d=example.net")
    assert verified?("MX.Example.Com; DKIM=PASS HEADER.D=Sign.Example.Net")
    assert_not verified?("mx.example.com; dkim=pass header.d=notexample.net")
    assert_not verified?("mx.example.com; dkim=pass header.d=example.net.example.com")
    assert_not verified?("mx.example.com; dkim=pass header.i=@example.net")
    assert_not verified?("mx.example.com; dkim=fail header.d=example.net; dkim=pass header.d=relay.example.com")
  end

  test "DMARC pass names the exact From domain and SPF does not count" do
    assert verified?("mx.example.com; dmarc=pass header.from=EXAMPLE.NET")
    assert_not verified?("mx.example.com; dmarc=pass header.from=sign.example.net")
    assert_not verified?("mx.example.com; dmarc=pass smtp.mailfrom=example.net")
    assert_not verified?("mx.example.com; spf=pass smtp.mailfrom=example.net")
  end

  test "folds, nested comments and quoted strings do not give up what is inside them as results" do
    assert verified?(<<~RESULTS.chomp)
      (inbound) "mx.example.com" 1;
       dkim (edge (checked)) = pass reason="kept ; as text" header.d="example.net"
    RESULTS
    assert_not verified?(<<~RESULTS.chomp)
      mx.example.com; dkim=pass (checking header.d=example.net)
       reason="not a pass: \\\"; dmarc=pass header.from=example.net" header.d=relay.example.com
    RESULTS
    assert_not verified?("mx.example.com; dkim=pass header.d=example.net (unclosed")
  end

  test "only the first Authentication-Results above the first Received header can count" do
    pass = "Authentication-Results: mx.example.com; dkim=pass header.d=example.net"
    fail_result = "mx.example.com; dkim=fail header.d=example.net"

    assert_not verified?(nil, below: pass)
    assert_not verified?(fail_result, below: pass)
    assert_not verified?("#{fail_result}\r\n#{pass}")
    assert_not verified?("mx.example.com; dkim=pass header.d=example.net", received: nil)
    assert_not verified?("mx.example.com; dkim=pass header.d=example.net", received: "X-Note: text\r\n #{RECEIVE}")
  end

  test "only configured authserv IDs count, regardless of case" do
    assert verified?("mx.example.com; dkim=pass header.d=example.net", authserv_id: "other.example.com, MX.EXAMPLE.COM ")
    assert_not verified?("mx.example.com.relay.example.net; dkim=pass header.d=example.net")
    assert_not verified?("mx.example.com; dkim=pass header.d=example.net", authserv_id: " , ")
  end

  test "there must be one From field with a single mailbox" do
    result = "mx.example.com; dkim=pass header.d=example.net"
    assert_not verified?(result, from: "lee@example.net, alex@example.net")
    assert_not verified?(result, from: "alex@example.com\r\nFrom: lee@example.net")
    assert_not verified?(result, from: nil)
    assert verified?(result, from: 'Lee <"Lee@Desk"@example.net>')
  end

  private
    def verified?(result, received: RECEIVE, below: nil, from: "Lee <lee@example.net>", authserv_id: "mx.example.com")
      source = [ ("Authentication-Results: #{result}" if result), received, below, ("From: #{from}" if from), "", "An answer." ].compact.join("\r\n")
      with_setting(:mail, :authserv_id, authserv_id) { MailAuthentication.new(Mail.new(source)).verified? }
    end
end
