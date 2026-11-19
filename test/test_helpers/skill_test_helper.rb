require "zip"

# Skill folders for tests: built in memory, zipped, or served by a stubbed
# GitHub. Nothing reaches the network.
module SkillTestHelper
  SHA = "1111111111111111111111111111111111111111".freeze
  NEWER = "2222222222222222222222222222222222222222".freeze

  def skill_md(name = "trip", description = "Use when planning a trip.", body = "# Trip\n\nRun scripts/plan.sh.")
    "---\nname: #{name}\ndescription: #{description}\nlicense: MIT\n---\n\n#{body}\n"
  end

  # { path => content } or { path => [content, executable] }.
  def skill_folder(files)
    Skill::Folder.new(files.map { |path, (content, executable)| Skill::Folder::Entry.new(path, content.b, Skill::Folder.executable?(path, content, executable.present?)) })
  end

  def zip_upload(files, name = "skill.zip")
    io = Zip::OutputStream.write_buffer(StringIO.new) do |zip|
      files.each do |path, (content, mode)|
        entry = Zip::Entry.new("", path)
        entry.unix_perms = mode if mode
        zip.put_next_entry(entry)
        zip.write(content)
      end
    end
    Rack::Test::UploadedFile.new(StringIO.new(io.string), "application/zip", true, original_filename: name)
  end

  def uploads(files)
    files.map { |path, content| Rack::Test::UploadedFile.new(StringIO.new(content), "application/octet-stream", original_filename: File.basename(path)) }
  end

  # A public repository at a commit: each ref answers with its SHA, the tree
  # lists every file with git's name for it, and each file's bytes come raw.
  # Returns the raw files' stubs, to count what was fetched.
  def stub_github(repo, files:, sha: SHA, refs: { "HEAD" => sha })
    refs.each { |ref, commit| stub_request(:get, "https://api.github.com/repos/#{repo}/commits/#{ref}").to_return(body: commit) }
    tree = files.map do |path, (content, mode)|
      { path: path, mode: mode || "100644", type: "blob", size: content.bytesize, sha: Skill::Folder.git_sha(content) }
    end
    stub_request(:get, "https://api.github.com/repos/#{repo}/git/trees/#{sha}?recursive=1").to_return(body: { sha: sha, tree: tree, truncated: false }.to_json)
    files.to_h { |path, (content, _)| [ path, stub_request(:get, "https://raw.githubusercontent.com/#{repo}/#{sha}/#{path}").to_return(body: content) ] }
  end

  def stub_github_missing(repo, ref = "HEAD")
    stub_request(:get, "https://api.github.com/repos/#{repo}/commits/#{ref}").to_return(status: 404, body: { message: "Not Found" }.to_json)
  end
end
