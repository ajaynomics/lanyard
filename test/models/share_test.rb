require "test_helper"

# The Share sheet's three fields become one message: the words once, a link
# once, a page's title before them.
class ShareTest < ActiveSupport::TestCase
  test "a title, words and a link, each once" do
    assert_equal "Worth a day trip?", Share.text_from(text: "Worth a day trip?")
    assert_equal "Sintra\nhttps://travel.example.com/sintra", Share.text_from(title: "Sintra", text: "https://travel.example.com/sintra", url: "")
    assert_equal "Sintra\nhttps://travel.example.com/sintra", Share.text_from(title: "Sintra", url: "https://travel.example.com/sintra")
    assert_equal "Read this: Sintra https://travel.example.com/sintra",
      Share.text_from(title: "Sintra", text: "Read this: Sintra https://travel.example.com/sintra", url: "https://travel.example.com/sintra")
    assert_equal "", Share.text_from
  end

  test "the words stay under a message's limit, whole characters only" do
    text = Share.text_from(text: "é" * Share::TEXT_BYTES)
    assert_operator text.bytesize, :<=, Share::TEXT_BYTES
    assert text.valid_encoding?
  end
end
