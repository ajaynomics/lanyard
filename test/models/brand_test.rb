require "test_helper"

# How the app presents itself to a workspace's people: the install's name,
# colour and address, or the workspace's own where they are set.
class BrandTest < ActiveSupport::TestCase
  test "a workspace that sets nothing goes by the install's name, colour and address" do
    brand = Workspace.create!(name: "Plain").brand

    assert_equal "Durable Assistants", brand.name
    assert_equal 255, brand.accent_hue
    assert_equal({}, brand.url_options)
    assert_equal [ "Durable Assistants", 255, {} ], Brand.install.then { [ it.name, it.accent_hue, it.url_options ] }
  end

  test "a workspace's own name, colour and link host" do
    with_setting(:app, :redirects, "office.example.net") do
      brand = Workspace.create!(name: "Field", app_name: " Field  Office ", accent_hue: 150, link_host: " Office.Example.NET. ").brand

      assert_equal "Field Office", brand.name
      assert_equal 150, brand.accent_hue
      assert_equal({ host: "office.example.net", protocol: "http" }, brand.url_options)
    end
  end

  test "a hue is a whole number of degrees, a name at most 40 characters: it fits the header" do
    workspace = Workspace.new(name: "Field")

    [ -1, 361, 1.5 ].each do |hue|
      workspace.accent_hue = hue
      assert_not workspace.valid?, "#{hue} is not a hue"
    end
    workspace.accent_hue = 0
    workspace.app_name = "x" * 41
    assert_equal [ "Name is too long (maximum is 40 characters)" ], workspace.tap(&:valid?).errors.full_messages
    workspace.app_name = "x" * 40
    assert workspace.valid?
  end

  test "a link host must be a name this install answers on, so a link never leads somewhere it does not" do
    workspace = Workspace.new(name: "Field", link_host: "office.example.net")
    assert_not workspace.valid?
    assert_equal [ "Link host must be a name this install answers on: APP__URL's or one of APP__REDIRECTS" ], workspace.errors.full_messages

    workspace.link_host = "https://office.example.net/x"
    assert_not workspace.valid?

    with_setting(:app, :redirects, "office.example.net") { assert workspace.tap { it.link_host = "office.example.net" }.valid? }
    workspace.link_host = "localhost"
    assert workspace.valid?, "APP__URL's own host"
  end

  test "a link host the install stopped answering on is no longer used: links go to APP__URL" do
    workspace = with_setting(:app, :redirects, "office.example.net") { Workspace.create!(name: "Field", link_host: "office.example.net") }

    assert_equal({}, workspace.brand.url_options)
  end
end
