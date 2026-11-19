# A record that may set the size of the Sprites made for an agent
# (Computer::Size): a workspace for all its agents, an agent's computer for
# its own. A part left blank is the next one's to set.
module SizesComputers
  extend ActiveSupport::Concern

  class_methods do
    # The column that holds each part.
    def sizes_computers(**columns)
      class_attribute :size_columns, instance_writer: false, default: columns.freeze
      validate :size_within_install
    end
  end

  # The parts it sets, as saved, nil for one it leaves: a size refused is in use nowhere.
  def own_size = size_columns.transform_values { attribute_in_database(it) }

  private
    def size_within_install
      maximum = Computer::Size.maximum
      size_columns.each do |part, column|
        next if (value = self[column]).nil?
        if value < 1
          errors.add(column, part == :cpus ? "must be at least 1" : "must be more than none")
        elsif value > maximum[part]
          most = part == :cpus ? maximum.cpus : Computer::Size.describe(part, maximum[part])
          errors.add(column, "can be at most #{most} on this install")
        end
      end
    end
end
