# Which signed-in session posted an iPhone's token (Push::Device.this_session):
# the session id's private digest, never the id itself, so Settings can say
# whether notifications are on for this iPhone rather than any of the
# person's. Additive: an existing row has none until the app posts its token
# again, at its next launch or return; code from before ignores the column.
class AddSessionDigestToPushDevices < ActiveRecord::Migration[8.2]
  def change
    add_column :push_devices, :session_digest, :string
  end
end
