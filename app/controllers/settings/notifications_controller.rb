# The kinds of notification the person wants (Push.deliver), switched in
# Settings, You, each saved as it changes.
class Settings::NotificationsController < ApplicationController
  def update
    Current.user.update!(params.expect(user: %i[ push_messages push_needs_you push_errors ]))
    saved settings_account_path
  end
end
