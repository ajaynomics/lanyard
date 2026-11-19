require "test_helper"

class IconsControllerTest < ActionDispatch::IntegrationTest
  test "the icon is drawn in the install's accent, at the size each place asks for" do
    with_setting(:app, :accent_hue, 160) do
      get icon_path("app", format: :png)
      assert_response :success
      assert_equal "image/png", response.media_type
      assert_equal [ 512, 512 ], response.body.byteslice(16, 8).unpack("N2")
      green = pixel(response.body, 512, 256, 40)

      get icon_path("app", format: :svg)
      assert_match %r{<svg}, response.body

      get "/apple-touch-icon.png"
      assert_equal [ 180, 180 ], response.body.byteslice(16, 8).unpack("N2")
      assert_equal 255, pixel(response.body, 180, 0, 0).last, "a phone rounds the corners itself, so the tile fills them"

      get "/favicon.ico"
      assert_equal "image/x-icon", response.media_type
      assert_equal [ 0, 1, 1 ], response.body.unpack("v3")

      with_setting(:app, :accent_hue, 30) do
        get icon_path("app", format: :png)
        assert_not_equal green, pixel(response.body, 512, 256, 40), "another hue, another colour"
      end
    end
  end

  test "the vector may be asked for in another hue, a workspace's own; a picture, or a hue that is not one, is the install's" do
    with_setting(:app, :accent_hue, 160) do
      get icon_path("favicon", format: :svg)
      install = response.body
      get icon_path("favicon", format: :svg, hue: 30)
      assert_not_equal install, response.body
      assert_equal Icon.for(30).svg, response.body

      [ "361", "-1", "1e2", "red" ].each do |hue|
        get icon_path("favicon", format: :svg, hue: hue)
        assert_equal install, response.body, hue
      end
      get icon_path("app", format: :png)
      png = response.body
      get icon_path("app", format: :png, hue: 30)
      assert_equal png, response.body, "pictures are drawn in the install's hue alone, so nobody can fill memory with them"
    end
  end

  test "the rounded icon's corners are clear" do
    get icon_path("app", format: :png)
    assert_equal 0, pixel(response.body, 512, 0, 0).last
  end

  test "only the icon's own names are served" do
    get "/icons/secrets.png"
    assert_response :not_found
  end

  private
    def pixel(png, size, x, y)
      at, data = 8, +"".b
      while at < png.bytesize
        length, type = png.byteslice(at, 8).unpack("Na4")
        data << png.byteslice(at + 8, length) if type == "IDAT"
        at += 12 + length
      end
      Zlib.inflate(data).byteslice(y * (size * 4 + 1) + 1 + x * 4, 4).bytes
    end
end
