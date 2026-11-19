# Every day (config/recurring.yml), deliberately global: a document deleted
# more than Document::PURGE_AFTER ago goes for good, with its versions. Until
# then a person may restore it (Document::Deletable).
class DocumentPurgeJob < ApplicationJob
  def perform
    Document.due_for_purge.find_each(&:destroy) # tenancy-ok: the purge clears every agent's long-deleted documents
  end
end
