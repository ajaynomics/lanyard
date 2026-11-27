class BindPhoneLocationRequests < ActiveRecord::Migration[8.2]
  def change
    add_column :invocations, :location_session_digest, :string
    add_column :invocations, :location_claimed_at, :datetime
  end
end
