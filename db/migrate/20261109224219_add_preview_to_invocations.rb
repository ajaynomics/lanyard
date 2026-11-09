# What an approval card showed and the approval is bound to: a draft as it
# would be sent, with a digest of it (Invocation#fetch_preview). Empty for
# every other call, so existing rows need nothing.
class AddPreviewToInvocations < ActiveRecord::Migration[8.2]
  def change
    add_column :invocations, :preview, :json
  end
end
