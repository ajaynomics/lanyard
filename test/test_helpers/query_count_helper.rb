# N+1 guards: a page costs the same number of queries for two records as for
# twelve. The first count is measured, not written down, so a change that adds
# one query everywhere does not break the guard; one that adds a query per row does.
#
# Tests run inside the executor, so the query cache outlives a request; each
# count starts with it empty, as a real request does.
module QueryCountHelper
  def queries_in(&block)
    ActiveRecord::Base.clear_query_caches_for_current_thread
    ActiveRecord::Base.lease_connection.materialize_transactions
    counter = ActiveRecord::Assertions::QueryAssertions::SQLCounter.new
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    counter.log.size
  end

  def assert_same_queries(baseline, &block)
    ActiveRecord::Base.clear_query_caches_for_current_thread
    assert_queries_count(baseline, &block)
  end
end
