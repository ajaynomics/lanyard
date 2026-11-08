# A saved prompt: `/name args` in the composer becomes its body, with the
# arguments put in, as pi's prompt templates do (docs/prompt-templates.md).
# Rails expands it in Conversation#submit, so it works without JavaScript and
# the model only ever sees the expanded text.
class Prompt < ApplicationRecord
  include Agent::Part

  # The composer's own commands. Their names are taken, so a typed command
  # always does what the help says it does.
  BUILT_IN = CommandsHelper::BUILT_IN_COMMANDS.map(&:name).freeze
  # pi's placeholders: ${N:-default}, ${@:-default}, ${@:N}, ${@:N:L}, $N, $@, $ARGUMENTS.
  PLACEHOLDER = /\$\{(\d+|ARGUMENTS|@):-([^}]*)\}|\$\{@:(\d+)(?::(\d+))?\}|\$(ARGUMENTS|@|\d+)/

  normalizes :name, with: -> { it.strip.delete_prefix("/") }
  validates :name, exclusion: { in: BUILT_IN, message: "is one of the built-in commands" }

  # Bash-style words: a quote groups words and is dropped; an empty word is
  # no word (pi's parseCommandArgs, character for character).
  def self.split_arguments(text)
    words, current, quote = [], +"", nil
    text.to_s.each_char do |char|
      if quote
        char == quote ? quote = nil : current << char
      elsif char == '"' || char == "'"
        quote = char
      elsif char.match?(/\s/)
        words << current unless current.empty?
        current = +""
      else
        current << char
      end
    end
    current.empty? ? words : words << current
  end

  # The body with the arguments in their places. A missing argument is empty,
  # never left as `$2`; an argument is not expanded again.
  def expand(arguments)
    words = self.class.split_arguments(arguments)
    all = words.join(" ")
    body.gsub(PLACEHOLDER) do
      default_of, default, from, length, simple = $1, $2, $3, $4, $5
      if default_of
        value = default_of.in?(%w[ @ ARGUMENTS ]) ? all : word(words, default_of)
        value.presence || default
      elsif from
        start = [ from.to_i - 1, 0 ].max
        (length ? words[start, length.to_i] : words[start..]).to_a.join(" ")
      elsif simple.in?(%w[ @ ARGUMENTS ])
        all
      else
        word(words, simple).to_s
      end
    end
  end

  # What the composer's list says beside it: the description, or the first
  # line of the body, as pi does.
  def hint
    description.presence || body.to_s.lines.map(&:strip).find(&:present?).to_s.truncate(60)
  end

  def to_s = "/#{name}"

  private
    # $1 is the first; $0 is nothing, as in pi, not the last.
    def word(words, number) = (words[number.to_i - 1] if number.to_i.positive?)
end
