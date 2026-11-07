# The session cookie holds the signed-in person's id, nothing else. Secure in
# production (over https only), never readable by scripts, and Lax so it comes
# back on the return from Ajent, a top-level GET from another site (Strict
# would drop it and the callback would find no session). A person stays signed
# in 30 days from their last visit; Rails enforces that inside the encrypted
# cookie, not just in the browser. The key is the name Rails chose before, so a
# deploy does not sign anyone out.
Rails.application.config.session_store :cookie_store,
  key: "_durable_assistants_session", expire_after: 30.days, secure: Rails.env.production?, httponly: true, same_site: :lax
