# A picture or file is served only to someone who reaches what it is attached
# to: a message in one of their workspaces' threads, a file an agent handed
# over there (Upload), or what their own Share sheet handed over. Its link is
# signed and never expires, so a link kept from a workspace someone has left,
# or passed on, would otherwise open it for anyone signed in. Active Storage
# finds the blob in blob_scope (ActiveStorage::SetBlob); this narrows it, and
# a blob outside it is not found. Current.user.messages and .conversations run
# through their memberships to every agent in those workspaces (User#agents),
# so a member reaches a picture in any member's thread there, never by
# authorship and never outside them. What a call holds for the sidecar
# (Invocation#held_files) is in none of them: nobody fetches it by its link,
# only the sidecar, through Sidecar::FilesController. A send's files
# (Conversation::Submission#files) are reached only as its message's, the
# same blobs once the message is recorded.
module ReachableBlobs
  private
    def blob_scope
      attachments = ActiveStorage::Attachment.where(record_type: "Message", record_id: Current.user.messages.select(:id))
        .or(ActiveStorage::Attachment.where(record_type: "Upload", record_id: Current.user.conversations.joins(:uploads).select("uploads.id")))
        .or(ActiveStorage::Attachment.where(record_type: "Share", record_id: Current.user.shares.select(:id)))
      ActiveStorage::Blob.where(id: attachments.select(:blob_id))
    end
end
