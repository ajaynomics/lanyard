module AnalyticsHelper
  # Rybbit's tag, on every page including sign-in, when the install has a
  # site. Replay is the Rybbit site's own setting; masking is this install's.
  def rybbit_tag
    analytics = Rails.configuration.x.analytics
    return if analytics.site_id.blank?

    masking = analytics.replay_masking
    tag.script src: URI.join(analytics.host, "/api/script.js").to_s, defer: true, data: {
      site_id: analytics.site_id,
      replay_mask_all_inputs: masking.to_s,
      replay_mask_input_options: { password: true, email: masking }.to_json
    }
  end
end
