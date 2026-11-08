# The icon in the install's accent (Icon), for browsers, phones and the
# manifest, before anyone signs in. Not an ApplicationController: an icon is
# not a visit, and an old phone fetching one is not turned away.
class IconsController < ActionController::Base
  def show
    icon = Icon.for(DurableAssistants.accent_hue)
    _, full_bleed = Icon::VARIANTS.fetch(params[:id])
    expires_in 1.day, public: true
    return unless stale?(etag: [ icon.hue, params[:id], request.format.symbol ], public: true)

    respond_to do |format|
      format.svg { send_data icon.svg(full_bleed:), type: :svg, disposition: :inline }
      format.png { send_data icon.png(params[:id]), type: :png, disposition: :inline }
      format.ico { send_data icon.ico, type: :ico, disposition: :inline }
    end
  end
end
