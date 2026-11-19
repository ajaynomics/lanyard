# The other install's sidecar numbered its entries in its own store, which
# does not come (docs/import.md); this one's numbers its own from 1. A thread
# that came starts afresh in this sidecar, so its entries move below zero, in
# the same order: they sort before anything this sidecar adds to the thread,
# and none shares a key with one of its own, which Conversation#sync! would
# otherwise take for an entry already recorded.
class Workspace::Import::Entries
  def initialize(source)
    @offset = [ source.maximum("messages", "entry_id"), source.maximum("conversations", "last_entry_id"),
                source.maximum("conversations", "forked_at_entry_id") ].compact.max.to_i + 1
  end

  def id(entry_id) = entry_id && Integer(entry_id) - @offset

  # An entry's key is its id, or its id and a part ("12:1").
  def key(entry_key) = entry_key.to_s.sub(/\A\d+/) { id(it).to_s }
end
