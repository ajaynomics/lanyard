# A unified diff of two texts, line by line, as `diff -u` writes it: what the
# agent reads of the person's changes to a document. A longest-common-
# subsequence table over the lines that differ, after the shared start and end
# are set aside; a pair too large for that is said as a replacement instead.
module Document::Diff
  CONTEXT = 3
  TABLE_LIMIT = 4_000_000

  def self.unified(old, new, from:, to:)
    a, b = old.lines(chomp: true), new.lines(chomp: true)
    return "" if a == b
    ops = operations(a, b)
    [ "--- #{from}", "+++ #{to}", *hunks(ops) ].join("\n")
  end

  # [ sign, line, line number in a, in b ] for every line of both, in order.
  def self.operations(a, b)
    head = a.zip(b).take_while { |x, y| x == y }.size
    tail = a[head..].reverse.zip(b[head..].reverse).take_while { |x, y| x == y }.size
    middle_a, middle_b = a[head...(a.size - tail)], b[head...(b.size - tail)]
    changed = if middle_a.size * middle_b.size > TABLE_LIMIT
      middle_a.map { [ "-", it ] } + middle_b.map { [ "+", it ] }
    else
      lcs(middle_a, middle_b)
    end
    ops = a.first(head).map { [ " ", it ] } + changed + a.last(tail).map { [ " ", it ] }
    i = j = 0
    ops.map do |sign, line|
      numbered = [ sign, line, i, j ]
      i += 1 unless sign == "+"
      j += 1 unless sign == "-"
      numbered
    end
  end

  def self.lcs(a, b)
    table = Array.new(a.size + 1) { Array.new(b.size + 1, 0) }
    a.size.downto(1) { |i| b.size.downto(1) { |j| table[i - 1][j - 1] = a[i - 1] == b[j - 1] ? table[i][j] + 1 : [ table[i][j - 1], table[i - 1][j] ].max } }
    i = j = 0
    ops = []
    while i < a.size && j < b.size
      if a[i] == b[j] then ops << [ " ", a[i] ]; i += 1; j += 1
      elsif table[i + 1][j] >= table[i][j + 1] then ops << [ "-", a[i] ]; i += 1
      else ops << [ "+", b[j] ]; j += 1
      end
    end
    ops + a[i..].map { [ "-", it ] } + b[j..].map { [ "+", it ] }
  end

  # Changes with CONTEXT lines either side, joined where their context meets.
  def self.hunks(ops)
    changed = ops.each_index.reject { ops[it][0] == " " }
    groups = changed.slice_when { |x, y| y - x > CONTEXT * 2 }
    groups.flat_map do |group|
      lines = ops[[ group.first - CONTEXT, 0 ].max..[ group.last + CONTEXT, ops.size - 1 ].min]
      old_count, new_count = lines.count { it[0] != "+" }, lines.count { it[0] != "-" }
      old_start = old_count.zero? ? lines.first[2] : lines.first[2] + 1
      new_start = new_count.zero? ? lines.first[3] : lines.first[3] + 1
      [ "@@ -#{old_start},#{old_count} +#{new_start},#{new_count} @@", *lines.map { "#{it[0]}#{it[1]}" } ]
    end
  end
end
