# Records what each run used (ModelUsage) from the running totals the
# sidecar reports for each model and tool, at a run's end and on a page
# load's look at the thread: what each added since the last report it
# recorded. A report repeated or out of date adds nothing.
module Conversation::Metering
  extend ActiveSupport::Concern

  # Before #usage takes the new totals, which say whether the thread is from
  # before metering: one that had used something with nothing recorded starts
  # counting here, rather than putting its whole history in this month.
  def meter(raw)
    rows = Usage.rows(raw) or return
    with_lock do
      ModelUsage.record(agent, rows, before: metered_usage, conversation: self, filed_under: filed_under) unless metered_usage.nil? && usage.to_h["totalTokens"].to_i.positive?
      update!(metered_usage: rows)
    end
  end

  # The next run must not inherit this file.
  def unfile
    update!(filed_under: nil) if filed_under
  end
end
