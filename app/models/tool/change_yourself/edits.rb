class Tool::ChangeYourself
  class Edits
    def initialize(base, edits)
      @base, @edits = base, edits
    end

    def changes
      @changes ||= begin
        if @edits.sum { |edit| edit.fetch("find").length + edit.fetch("replace").length } > 2 * LIMIT
          raise Tool::Refusal, "The batch has too much text. Use shorter edits or a rewrite."
        end
        sorted = @edits.map.with_index(1) { |edit, number| match(edit, number) }.sort_by(&:offset)
        if sorted.each_cons(2).any? { |left, right| left.offset + left.from.length > right.offset }
          raise Tool::Refusal, "The edits overlap. Each must change a different part of the saved instructions."
        end
        sorted
      end
    end

    def result
      length = @base.length + changes.sum { |change| change.to.length - change.from.length }
      raise Tool::Refusal, "Instructions would exceed #{LIMIT} characters." if length > LIMIT

      cursor = 0
      changes.each_with_object(+"") do |change, text|
        text << @base[cursor...change.offset] << change.to
        cursor = change.offset + change.from.length
      end << @base[cursor..]
    end

    private
      def match(edit, number)
        from, to = edit.values_at("find", "replace")
        raise Tool::Refusal, "Edit #{number} makes no change." if from == to

        offset = @base.index(from)
        raise Tool::Refusal, "Edit #{number} does not match the saved instructions." unless offset
        # Start at the next character so that even overlapping occurrences count.
        raise Tool::Refusal, "Edit #{number} matches more than once." if @base.index(from, offset + 1)

        Change.new(offset, from, to)
      end
  end
end
