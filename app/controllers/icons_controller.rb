# The icon in the install's accent (Icon), for browsers, phones and the
# manifest, before anyone signs in. Not an ApplicationController: an icon is
# not a visit, and an old phone fetching one is not turned away.
class IconsController < ActionController::Base
  # An icon never shows the flash. Rails puts the flash in every ETag, and reading
  # it spends it: a browser's favicon fetch between a redirect and its page (the
  # phone app's refresh_historical_location) would eat the page's message.
  self.etaggers = []

  def show
    icon = Icon.for(hue)
    _, full_bleed = Icon::VARIANTS.fetch(params[:id])
    expires_in 1.day, public: true
    return unless stale?(etag: [ icon.hue, params[:id], request.format.symbol ], public: true)

    respond_to do |format|
      format.svg { send_data icon.svg(full_bleed:), type: :svg, disposition: :inline }
      format.png { send_data icon.png(params[:id]), type: :png, disposition: :inline }
      format.ico { send_data icon.ico, type: :ico, disposition: :inline }
    end
  end

  private
    # The vector in a workspace's own hue (Brand), for its pages' header.
    # Pictures, kept once drawn, are the install's alone: any hue asked of
    # them would be another set kept.
    def hue
      asked = Integer(params[:hue].to_s, 10, exception: false) if request.format.svg?
      asked && (0..360).cover?(asked) ? asked : DurableAssistants.accent_hue
    end
end
