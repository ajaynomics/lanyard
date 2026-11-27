module Workspace::ToolSwitches
  extend ActiveSupport::Concern

  included do
    validate :asks_every_names_are_supported
  end

  def self.install_list(setting)
    DurableAssistants.config(:app, setting, default: [])
  end

  def self.validate_install!
    unsupported = install_list(:asks_every) - Tool::AsksEverySend::SETTINGS.keys
    raise ArgumentError, "APP__ASKS_EVERY includes unsupported tools: #{unsupported.to_sentence}" if unsupported.any?
  end

  def tool_off?(name) = disabled_tools.include?(name) || install_tool_off?(name)
  def asks_every?(name) = asks_every.include?(name) || install_asks_every?(name)

  def install_tool_off?(name) = Workspace::ToolSwitches.install_list(:disabled_tools).include?(name)
  def install_asks_every?(name) = Workspace::ToolSwitches.install_list(:asks_every).include?(name)

  def tool_switch_names
    Tool::Catalog.built_ins.map(&:tool_name) | mcp_servers.flat_map { it.listed_tools.map(&:tool_name) } | disabled_tools
  end

  def tool_off_source(name)
    if install_tool_off?(name) then "this install"
    elsif disabled_tools.include?(name) then to_s
    end
  end

  def asks_every_source(name)
    if install_asks_every?(name) then "this install"
    elsif asks_every.include?(name) then to_s
    end
  end

  private
    def asks_every_names_are_supported
      unless asks_every.is_a?(Array) && (asks_every - Tool::AsksEverySend::SETTINGS.keys).empty?
        errors.add(:asks_every, "must list only email, text, iMessage and Concourse sends")
      end
    end
end
