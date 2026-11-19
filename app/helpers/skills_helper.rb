module SkillsHelper
  SHEBANG = /\A#!\S*?(?:env\s+)?\S*?\b(bash|sh|zsh|python3?|node|ruby|perl)\b/
  SHEBANG_LANGUAGES = { "python3" => "py", "python" => "py", "node" => "js", "zsh" => "sh", "bash" => "sh", "ruby" => "rb", "perl" => "pl" }.freeze

  # A skill's state as a word and a colour (Skill::Review).
  def skill_state(skill)
    kind, words = if skill.needs_review? then [ "attention", "Waiting for your review" ]
    elsif skill.rejected? then [ "error", "Rejected" ]
    else [ "connected", "Ready" ]
    end
    tag.span(tag.span(class: "ui-status__dot") + words, class: "ui-status", data: { kind: kind })
  end

  # A file's contents, highlighted as its extension or shebang says, through
  # the same renderer and sanitizer as a reply (ApplicationHelper#markdown).
  def skill_file_contents(path, content)
    return tag.p("Not text, so it isn't shown.", class: "muted") unless Skill::Folder.text?(content)
    text = content.dup.force_encoding(Encoding::UTF_8)
    fence = "`" * [ 3, text.scan(/`+/).map(&:size).max.to_i + 1 ].max
    tag.div(markdown("#{fence}#{skill_file_language(path, text)}\n#{text.chomp}\n#{fence}"), class: "ui-markdown skill-file__contents")
  end

  def skill_file_language(path, text)
    # Letters and digits only: a backtick would end the fence's first line, and
    # the file would show as Markdown, hiding what a comment holds.
    File.extname(path).delete_prefix(".").gsub(/[^A-Za-z0-9_+-]/, "").presence || SHEBANG_LANGUAGES.fetch(text[SHEBANG, 1].to_s, "")
  end

  def skill_file_size(bytes) = number_to_human_size(bytes)
end
