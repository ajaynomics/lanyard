# A routine may run once at a time (#81) rather than on a repeating schedule.
# Additive and nullable: existing routines, and any code from before writes
# during a rolling deploy, repeat as before. schedule stays NOT NULL: a one-off
# also keeps its minute, hour, day and month as cron there (Routine#pin), so
# code from before, still running jobs during the deploy or after a rollback,
# reads it as a routine it can run, at the same minute, rather than failing
# its sweep on a blank schedule. That code would run it again a year on
# instead of deleting it; the person sees it on the page and can delete it.
class AddOnceAtToRoutines < ActiveRecord::Migration[8.2]
  def change
    add_column :routines, :once_at, :datetime
  end
end
