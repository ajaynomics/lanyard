# Pages as the phone app shows them (docs/native-app.md): the app draws its own
# bar, titled from the page's <title>, so a page there says its own name
# alone and leaves the web's header, back links and sidebar out.
module NativeAppHelper
  # The page's name, then the app's, in a browser's tab; the page's own name
  # alone in the app's bar ("You", not "You · Settings · Lanyard").
  def page_title
    if hotwire_native_app?
      content_for(:title).to_s.split(" · ").first.presence || app_name
    else
      [ content_for(:title), app_name ].compact_blank.uniq.join(" · ")
    end
  end
end
