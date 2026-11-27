# Whether iOS last refused an iPhone's notifications, as the app says each time
# it comes to the front (Push::Device#reported). Existing devices are not refused.
class AddRefusedToPushDevices < ActiveRecord::Migration[8.2]
  def change
    add_column :push_devices, :refused, :boolean, default: false, null: false
  end
end
