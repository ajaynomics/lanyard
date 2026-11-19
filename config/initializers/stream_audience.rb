# Every stream asks who hears it (StreamAudience), Turbo's own channel too:
# any channel can be subscribed to by name, so guarding only ours would not
# guard the streams. In to_prepare, as Active Storage's sign-in is, so a
# reload keeps it.
Rails.application.config.to_prepare do
  Turbo::StreamsChannel.prepend StreamAudience unless Turbo::StreamsChannel <= StreamAudience
end
