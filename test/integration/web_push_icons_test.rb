require "test_helper"
require "open3"

class WebPushIconsTest < ActionDispatch::IntegrationTest
  test "web push uses the install icon and a separate silhouette by default" do
    get pwa_service_worker_path
    assert_response :success
    assert_worker_contract
    assert_match %r{icon: "/icons/app-192\.png"}, response.body
    assert_image "badge", "push-badge", 96
  end

  private
    def assert_worker_contract
      assert_equal Mime[:js].to_s, response.media_type
      script = Rails.root.join("test/test_helpers/service_worker_contract.mjs")
      output, status = Open3.capture2e("node", script.to_s, stdin_data: response.body)
      assert status.success?, output
    end

    def assert_image(option, filename, size)
      assert_png image_path_in_script(option, filename), size
    end

    def image_path_in_script(option, filename)
      response.body.match(%r{#{option}: "(/assets/notifications/#{filename}-[a-f0-9]+\.png)"})&.captures&.sole || flunk("missing #{option} image")
    end

    def assert_png(path, size)
      get path
      assert_response :success
      assert_equal "image/png", response.media_type
      assert_equal [ size, size ], response.body.byteslice(16, 8).unpack("N2")
    end
end
