# Settings, Notifications: notifications on this device, the browser's (Web
# Push) or, in the phone app, this iPhone's (Push::Device), and the kinds of
# notification the person wants (Push.deliver), each saved as it changes.
class Settings::NotificationsController < ApplicationController
  layout "settings"

  def show
    @this_iphone = Current.user.push_devices.this_session(session) if hotwire_native_app?
  end

  def update
    Current.user.update!(params.expect(user: %i[ push_messages push_needs_you push_errors ]))
    saved settings_notifications_path
  end
end
