# The choices for one part of a Sprite's size (Computer::Size), on the
# workspace's page and the agent's Computer page: first what a blank leaves it
# to (`fallback`, named by `label`), then the sizes the install allows, with
# whatever is saved even if it no longer is.
module ComputerSizesHelper
  def computer_size_options(part, saved:, fallback:, label:)
    values = (Computer::Size.choices(part) | [ saved ].compact).sort
    [ [ "#{label} (#{Computer::Size.describe(part, fallback[part])})", "" ] ] +
      values.map { [ Computer::Size.describe(part, it), it ] }
  end
end
