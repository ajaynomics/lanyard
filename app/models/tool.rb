# A tool is what the model may ask the app to do for a person. Each one is a
# small class: one JSON Schema for its arguments, its own rules for who may use
# it and whether a person must answer first, and a `call` that delegates to the
# domain. Tool calls arrive through Invocation, the one ledger that makes a
# call replayed by the sidecar after a crash run once.
#
#   class Tool::RememberNote < Tool
#     description "Save or replace a note by key."
#     argument :key, :string, max_length: 64
#     def call(key:) = agent.notes.remember(key, ...)
#   end
class Tool
  # A refusal the model should read and can act on, rather than a crash.
  class Refusal < StandardError; end

  class << self
    def tool_name = name.demodulize.underscore

    def description(text = nil)
      text ? @description = text : @description
    end

    # nil (just run), :approval (a person allows or denies the exact call) or
    # :question (the call waits for a person's answer, which is its result).
    # always: false when a person must allow every call, never "Always".
    def asks(kind = nil, always: true)
      return @asks unless kind
      @asks, @always = kind, always
    end

    def always? = @always != false

    # :database (the work commits with its record, so it runs exactly once) or
    # :external (the call leaves this database: the ledger commits that it is
    # running first, and makes the call outside any transaction).
    def effect(kind = nil)
      kind ? @effect = kind : (@effect || :database)
    end

    # One JSON Schema property. Keywords are JSON Schema's, in Ruby case
    # (max_length: becomes maxLength). Patterns must be ECMA-262: the sidecar
    # checks the same schema in JavaScript.
    def argument(name, type, required: true, **keywords)
      arguments[name.to_s] = { "type" => type.to_s, **keywords.to_h { |key, value| [ key.to_s.camelize(:lower), value ] } }.deep_stringify_keys
      required_arguments << name.to_s if required
    end

    def arguments = @arguments ||= {}
    def required_arguments = @required_arguments ||= []

    def schema
      { "type" => "object", "additionalProperties" => false, "properties" => arguments, "required" => required_arguments }
    end

    def errors_for(values)
      JSONSchemer.schema(schema, regexp_resolver: "ecma").validate(values).map { it["error"] }
    end

    def declaration
      { name: tool_name, description: description, parameters: schema }
    end
  end

  attr_reader :invocation
  delegate :conversation, :agent, :user, to: :invocation

  def initialize(invocation)
    @invocation = invocation
  end

  # Whether the sidecar fills the browser after this call (Tool::SignInWithSavedPassword).
  def self.fills? = false

  # Whether a person answers first; a tool may decide by its arguments (Tool::SendEmail).
  def asks = self.class.asks

  # A tool's own condition beyond the agent listing it, checked before it runs
  # and again after a person approves.
  def permitted? = true

  # Whether a person may answer this tool "Always" (Permission), the name it is
  # granted under, and whom a call reaches, for "Always with" them: none for a
  # tool that reaches no one in particular. Read from the call as recorded.
  def always? = self.class.always?
  def permission_name = invocation.tool_name
  def recipients = []

  def call(**) = raise NotImplementedError
end
