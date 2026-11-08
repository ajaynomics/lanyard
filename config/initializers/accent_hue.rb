# A hue that is not a number of degrees fails the boot, in every
# environment, rather than leave every screen grey (DurableAssistants.accent_hue).
Rails.application.config.after_initialize { DurableAssistants.accent_hue }
