# How big an agent's Sprite is made: whole CPUs, and memory and disk in MiB,
# as the Sprites platform takes them. The install's default is the size every
# Sprite was made with before sizes were settings, and the bridge's when Rails
# sends none (agent/sprites-bridge.mjs, DEFAULT_SIZE). A workspace's default,
# then an agent's own, override it part by part, never past the install's
# maximum (PI_DURABLE__COMPUTER_MAX_*), which is the default unless set.
# A size is fixed when its Sprite is made: a new one reaches only Sprites made
# after it, a new conversation's or one an operator remakes (docs/agent.md).
class Computer::Size < Data.define(:cpus, :memory_mib, :disk_mib)
  # What the pages offer, up to the install's maximum; any whole number within it is valid.
  CHOICES = { cpus: [ 1, 2, 4, 8, 16 ], memory_mib: [ 1, 2, 4, 8, 16, 32 ].map { it * 1024 },
              disk_mib: [ 8, 16, 32, 64, 128, 256 ].map { it * 1024 } }.freeze

  def self.default = new(cpus: 2, memory_mib: 2048, disk_mib: 8192)

  def self.maximum
    new(**default.to_h.to_h { |part, value| [ part, Integer(DurableAssistants.config(:pi_durable, :computer_maximum, part, default: value)) ] })
  end

  # Each part from the first of the layers (hashes of part to value, nil for
  # unset) that sets it, else the default; never more than the maximum, so an
  # install that lowers it makes no Sprite bigger, whatever was saved before.
  def self.resolve(*layers)
    ceiling = maximum
    new(**members.to_h { |part| [ part, [ layers.filter_map { it[part] }.first || default[part], ceiling[part] ].min ] })
  end

  def self.choices(part) = CHOICES.fetch(part).select { it <= maximum[part] }

  # One part as a person reads it: "2 CPUs", "4 GiB".
  def self.describe(part, value)
    return "#{value} #{"CPU".pluralize(value)}" if part == :cpus
    "#{(value / 1024.0).round(1).to_s.delete_suffix(".0")} GiB"
  end

  def [](part) = public_send(part)

  def default? = self == self.class.default

  # As the sidecar takes it, in the computer's descriptor.
  def descriptor = { cpus: cpus, memoryMib: memory_mib, diskMib: disk_mib }

  # As the screen's query and the bridge's --size take it.
  def to_param = [ cpus, memory_mib, disk_mib ].join(",")

  def to_s
    "#{self.class.describe(:cpus, cpus)}, #{self.class.describe(:memory_mib, memory_mib)} memory, #{self.class.describe(:disk_mib, disk_mib)} disk"
  end
end
