require "test_helper"
require_relative "../test_helpers/agent_test_helper"

# Deleted documents wait Document::PURGE_AFTER to be restored, then go for good.
class DocumentPurgeJobTest < ActiveJob::TestCase
  include AgentTestHelper

  test "removes only documents deleted more than 30 days ago, versions and all, whoever's they are" do
    agent = create_user(name: "Maya").agents.sole
    other = create_user(name: "Robin").agents.sole
    old = written(agent, "Old").tap { it.soft_delete(by: "agent") }.tap { it.update_columns(deleted_at: 31.days.ago) }
    theirs = written(other, "Theirs").tap { it.soft_delete(by: "person") }.tap { it.update_columns(deleted_at: 40.days.ago) }
    recent = written(agent, "Recent").tap { it.soft_delete(by: "person") }.tap { it.update_columns(deleted_at: 29.days.ago) }
    kept = written(agent, "Kept").tap { it.update_columns(updated_at: 90.days.ago) }

    DocumentPurgeJob.perform_now

    assert_equal [ recent.id, kept.id ], Document.where(id: [ old, theirs, recent, kept ]).order(:id).pluck(:id) # tenancy-ok: the test checks every agent's
    assert_empty Document::Version.where(document_id: [ old.id, theirs.id ]) # tenancy-ok: the test checks every agent's
  end

  test "a document deleted 29 days ago is still restorable, under its own title" do
    agent = create_user(name: "Maya").agents.sole
    document = written(agent, "Plan").tap { it.soft_delete(by: "agent") }.tap { it.update_columns(deleted_at: 29.days.ago) }

    DocumentPurgeJob.perform_now
    agent.deleted_documents.find(document.id).undelete

    assert_equal [ "Plan", nil ], document.reload.then { [ it.title, it.deleted_at ] }
    assert_equal "Plan body", agent.documents.find(document.id).current_version.body
  end

  test "runs every day" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production")
    assert_equal "DocumentPurgeJob", schedule.dig("document_purge", "class")
    assert_match(/every day/, schedule.dig("document_purge", "schedule"))
  end

  private
    def written(agent, title) = agent.documents.create!(title: title).tap { it.revise("#{title} body", by: "agent") }
end
