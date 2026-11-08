# The app's own analytics: a row per visit and per event that matters, in its
# own database, where it joins to people and agents. Rybbit sees pages; this
# sees what people did. Events carry ids and choices, never what anyone wrote.
class Ahoy::Store < Ahoy::DatabaseStore
end

# Visits are the people's: the sidecar's callbacks, webhooks, Concourse pushes,
# pictures and the PWA files are not visits.
Ahoy.exclude_method = ->(controller, _request) { !controller.is_a?(ApplicationController) }

# The visit opens before require_sign_in names the person, so ask the session.
Ahoy.user_method = ->(controller) { Current.user || User.find_by(id: controller&.session&.dig(:user_id)) } # tenancy-ok: the session names the signed-in person

# Server-side only: no ahoy.js, no beacon endpoint, no geocoding.
Ahoy.api = false
Ahoy.geocode = false
Ahoy.mask_ips = true
# Nothing in the browser reads Ahoy's cookies.
Ahoy.cookie_options = { httponly: true, secure: Rails.env.production? }
