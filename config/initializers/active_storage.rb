# Pictures (what a conversation's screen showed, what a person sent) are served by
# Active Storage, whose links answer to anyone holding one unless its
# controllers ask for the sign-in. Nothing else stands in front of them once
# Cloudflare Access is gone.
#
# Not config.active_storage.base_controller_parent: Rails applies that after
# eager loading, so in production (and CI) the controllers are already loaded
# with ActionController::Base as their parent and the setting does nothing.
#
# Signed in is not enough: a blob is found only among those attached to what
# the person reaches (ReachableBlobs). Included in each controller that finds
# one, after ActiveStorage::SetBlob, so its blob_scope is the one used.
Rails.application.config.to_prepare do
  ActiveStorage::BaseController.include Authentication
  [ ActiveStorage::Blobs::RedirectController, ActiveStorage::Blobs::ProxyController, ActiveStorage::Representations::BaseController ]
    .each { it.include ReachableBlobs }
end
