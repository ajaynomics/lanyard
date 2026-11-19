# Tasks sent before progress notes were passed on (#66) are marked, so each
# one still working gets one summary of the notes it missed instead of all
# of them, and a finished one gets none (ConcourseAgent#catch_up). New rows
# take the default, so an old release still writing during a rolling
# deploy makes none to catch up.
class AddNotesFollowedToPeerTasks < ActiveRecord::Migration[8.2]
  def up
    add_column :peer_tasks, :notes_followed, :boolean, default: true, null: false
    execute "UPDATE peer_tasks SET notes_followed = FALSE"
  end

  def down
    remove_column :peer_tasks, :notes_followed
  end
end
