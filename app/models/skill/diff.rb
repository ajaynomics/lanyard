# What an update would change in a skill (Agents::Skills::UpdatesController):
# each file added, removed or changed, a text file's lines with three lines
# of context around each change, as `diff -u` shows them.
class Skill::Diff
  CONTEXT = 3
  # Past this many line pairs, a changed part is shown removed and added whole.
  CELLS = 250_000

  Change = Data.define(:path, :status, :lines, :note)

  # Each side is { path => [content, executable] }.
  def self.between(skill, folder)
    before = { Skill::Folder::MARKDOWN => [ skill.to_markdown, false ] }.merge(skill.files.to_h { [ it.path, [ it.content, it.executable ] ] })
    after = { Skill::Folder::MARKDOWN => [ Skill.from_markdown(folder.markdown).to_markdown, false ] }.merge(folder.bundled.to_h { [ it.path, [ it.content, it.executable ] ] })
    new(before, after)
  end

  def initialize(before, after)
    @changes = (before.keys | after.keys).sort.filter_map { change(it, before[it], after[it]) }
  end

  attr_reader :changes

  def empty? = changes.empty?

  private
    def change(path, before, after)
      return if before == after
      status = before.nil? ? "added" : after.nil? ? "removed" : "changed"
      old, new = before&.first.to_s, after&.first.to_s
      note = ("now runs as a program" if after&.last && !before&.last) || ("no longer runs as a program" if before&.last && after && !after.last)
      if Skill::Folder.text?(old) && Skill::Folder.text?(new)
        Change.new(path, status, lines(old, new), note)
      else
        Change.new(path, status, nil, [ note, "not text: #{size(old)} before, #{size(new)} after" ].compact.join("; "))
      end
    end

    def size(bytes) = ActiveSupport::NumberHelper.number_to_human_size(bytes.bytesize)

    def lines(old, new)
      a, b = text(old), text(new)
      head = 0
      head += 1 while head < a.size && head < b.size && a[head] == b[head]
      tail = 0
      tail += 1 while tail < a.size - head && tail < b.size - head && a[-1 - tail] == b[-1 - tail]
      same = ->(range) { a[range].map { [ " ", it ] } }
      collapse(same.(0...head) + middle(a[head...(a.size - tail)], b[head...(b.size - tail)]) + same.((a.size - tail)..))
    end

    def text(bytes) = bytes.dup.force_encoding(Encoding::UTF_8).lines(chomp: true)

    # The longest common run of lines, walked into removals and additions.
    def middle(a, b)
      return a.map { [ "-", it ] } + b.map { [ "+", it ] } if a.size * b.size > CELLS
      table = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
      (a.size - 1).downto(0) do |i|
        (b.size - 1).downto(0) { |j| table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : [ table[i + 1][j], table[i][j + 1] ].max }
      end
      i = j = 0
      ops = []
      while i < a.size && j < b.size
        if a[i] == b[j]
          ops << [ " ", a[i] ]
          i += 1
          j += 1
        elsif table[i + 1][j] >= table[i][j + 1]
          ops << [ "-", a[i] ]
          i += 1
        else
          ops << [ "+", b[j] ]
          j += 1
        end
      end
      ops + a[i..].map { [ "-", it ] } + b[j..].map { [ "+", it ] }
    end

    # Unchanged lines far from any change become one ["…", count] line.
    def collapse(ops)
      near = ops.each_index.select { ops[it].first != " " }.flat_map { ((it - CONTEXT)..(it + CONTEXT)).to_a }.to_set
      ops.each_with_index.chunk_while { |(_, i), (_, j)| near.include?(i) == near.include?(j) }.flat_map do |run|
        near.include?(run.first.last) ? run.map(&:first) : [ [ "…", run.size ] ]
      end
    end
end
