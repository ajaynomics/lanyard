require "test_helper"

class IconTest < ActiveSupport::TestCase
  test "every size is a PNG of its own size, from masks drawn from the vector" do
    Icon::VARIANTS.each do |name, (size, _)|
      png = Icon.new(200).png(name)
      assert png.start_with?(Icon::Png::SIGNATURE), name
      assert_equal [ size, size ], png.byteslice(16, 8).unpack("N2"), name
    end
  end

  test "the accent is the tile's colour, in the vector and the pictures alike" do
    assert_match "#", Icon.new(160).svg
    assert_not_equal Icon.new(160).svg, Icon.new(30).svg
    assert_not_equal Icon.new(160).png("favicon"), Icon.new(30).png("favicon")
  end

  test "a favicon.ico holds the 32px picture" do
    ico = Icon.new(255).ico
    assert_equal [ 0, 1, 1 ], ico.unpack("v3")
    assert_equal Icon.new(255).png("favicon"), ico.byteslice(22..)
  end
end
