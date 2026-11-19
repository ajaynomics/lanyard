# Where Settings opens (⌘,): on a phone, the list of places; on a wide screen,
# the sidebar; in the phone app, its Settings tab. As JSON, the same places,
# with Notifications' status for this phone beside it, for builds reading
# ios_v2, whose Settings tab is their own screen drawing a row for each.
class SettingsController < ApplicationController
  layout "settings"

  def show
    respond_to do |format|
      format.html
      format.json do
        render json: { sections: helpers.settings_groups.map { |title, places|
          { title: title, places: places.map { |id, name, path|
            { id: id, name: name, path: path, value: (helpers.notifications_status if id == "notifications") }.compact } } } }
      end
    end
  end
end
