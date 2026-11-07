# Pictures (what an agent's screen showed, what a person sent) are served by
# Active Storage, whose links answer to anyone holding one unless its
# controllers ask for the sign-in. Nothing else stands in front of them once
# Cloudflare Access is gone.
#
# Not config.active_storage.base_controller_parent: Rails applies that after
# eager loading, so in production (and CI) the controllers are already loaded
# with ActionController::Base as their parent and the setting does nothing.
Rails.application.config.to_prepare do
  ActiveStorage::BaseController.include Authentication
end
