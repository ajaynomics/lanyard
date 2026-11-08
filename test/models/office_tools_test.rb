require "test_helper"

# What the office's connectors let agents do (config/install_connectors.yml),
# checked against every tool the version config/deploy.example.yml pins
# offers (test/lib/office/, from each server's tools/list). A new version's
# list goes beside the old one, and this test says what the rule now admits.
class OfficeToolsTest < ActiveSupport::TestCase
  PEOPLES_VERBS = /\A(delete|destroy|merge|restore)_/

  test "the wiki: agents read it and write documents, comments and attachments; collections and deletion are people's" do
    assert_equal %w[ create_attachment create_comment create_document fetch get_document_changes list_collection_documents
      list_collections list_comments list_documents list_templates list_users move_document update_comment update_document ],
      offered(:wiki, "outline_1_12_0")
  end

  test "the CRM: agents read every record and write the everyday ones; the CRM itself, mail and deletion are people's" do
    offered = offered(:crm, "twenty_v2_56_1")
    reads, writes = offered.partition { it.start_with?("find_one_", "find_many_", "group_by_") }

    assert_operator reads.size, :>, 80
    records = %w[ person company opportunity note task attachment note_target task_target ]
    assert_equal records.sort, writes.map { it[/\A(create|update|upsert)_(one|many)_(.+)\z/, 3].singularize }.uniq.sort
    assert_empty offered.grep(/workflow|view|metadata|role|webhook|dashboard|email|campaign|connected_account|permission/) - reads
  end

  test "no office connector offers deleting, merging or restoring" do
    Rails.application.config.x.install_connectors.each_key do |name|
      assert_empty offered(name, listed_for(name)).grep(PEOPLES_VERBS), "#{name} offers a verb that is people's"
    end
  end

  private
    def listed_for(name) = { wiki: "outline_1_12_0", crm: "twenty_v2_56_1" }.fetch(name)

    def offered(name, listed)
      patterns = Rails.application.config.x.install_connectors.dig(name, :tools)
      File.readlines(Rails.root.join("test/lib/office/#{listed}.txt"), chomp: true).select { |tool| patterns.any? { File.fnmatch?(it, tool, File::FNM_EXTGLOB) } }
    end
end
