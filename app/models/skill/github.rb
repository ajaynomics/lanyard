# A skill in a public GitHub repository (docs/skills.md), named as
# `npx skills add` names one: owner/repo, owner/repo@skill, or a link to the
# skill's folder on github.com. Nothing is signed in. It fetches the folder
# at one commit, which the skill is pinned to until a person applies an
# update.
class Skill::Github
  REPO = %r{[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9._-]{1,100}}
  SHORTHAND = %r{\A(#{REPO})(?:@([A-Za-z0-9-]{1,64}))?\z}
  LINK = %r{\Ahttps?://(?:www\.)?github\.com/(#{REPO})(?:\.git)?(?:/(?:tree|blob)/([^?#]+))?/?(?:[?#].*)?\z}
  # Where `npx skills` looks in a repository, in its order (discoverSkills):
  # the top, then these folders, each three levels deep; anywhere else only
  # when they hold none.
  PLACES = %w[ skills skills/.curated skills/.experimental skills/.system .agents/skills data/skills .claude/skills ].freeze
  DEPTH = 3
  # A branch name may hold slashes, so a link's first few steps are each
  # tried as the branch.
  REF_STEPS = 4

  Invalid = Skill::Folder::Invalid
  TOO_LARGE = "This repository is too large to read whole; link the skill's folder directly."

  attr_reader :repo, :path, :ref, :skill

  def self.parse(text)
    text = text.to_s.strip
    if (match = text.match(SHORTHAND))
      new(repo: match[1], skill: match[2])
    elsif (match = text.match(LINK))
      new(repo: match[1].delete_suffix(".git"), link: match[2])
    else
      raise Invalid, "That isn't a skill on GitHub. Write owner/repo@skill, or paste the link to the skill's folder on github.com."
    end
  end

  # The skill a pinned skill came from, to check for an update.
  def self.for(skill) = new(repo: skill.github_repo, path: skill.github_path.to_s, ref: skill.github_ref)

  def initialize(repo:, path: nil, ref: nil, skill: nil, link: nil)
    @repo, @path, @ref, @skill, @link = repo, path, ref, skill, link
  end

  def name = [ repo, path.presence ].compact.join("/")

  # The commit the skill's ref names now: a branch moves, a SHA doesn't.
  def latest_sha = commit(ref || "HEAD")

  # The skill's folder at a commit (the latest when none), and where it came
  # from, for the skill's github_ columns. Files already held are known by
  # git's name for them, and not fetched again.
  def fetch(sha: nil, known: [])
    sha ||= @link ? resolve_link : latest_sha
    blobs = tree(sha)
    @path ||= locate(blobs)
    inside = blobs.select { path.empty? || it["path"].start_with?("#{path}/") }
    raise Invalid, "There is no SKILL.md in #{repo} at #{path.presence || 'its top'}." unless inside.any? { it["path"] == File.join(*[ path.presence, Skill::Folder::MARKDOWN ].compact) && it["type"] == "blob" }
    check(inside)
    known = known.index_by(&:git_sha)
    entries = inside.select { it["type"] == "blob" }.map { entry(it, sha, known) }
    [ Skill::Folder.new(entries), { github_repo: repo, github_path: path, github_ref: ref, github_sha: sha } ]
  end

  private
    def commit(ref)
      DurableAssistants::Github.commit(repo, ref)
    rescue DurableAssistants::Github::NotFound
      raise Invalid, "There is no public repository at github.com/#{repo}." if ref == "HEAD" || !repository?
      raise Invalid, "#{repo} has no branch, tag or commit called #{ref}."
    rescue DurableAssistants::Github::Error => error
      raise Invalid, error.message
    end

    def repository?
      DurableAssistants::Github.commit(repo, "HEAD")
      true
    rescue DurableAssistants::Github::NotFound
      false
    end

    # tree/<branch>/<folder>: the branch is the first steps that name a commit.
    def resolve_link
      steps = @link.to_s.split("/")
      steps = steps[...-1] if steps.last == Skill::Folder::MARKDOWN
      return latest_sha.tap { @path = "" } if steps.empty?
      (1..[ steps.size, REF_STEPS ].min).each do |count|
        sha = DurableAssistants::Github.commit(repo, steps.first(count).join("/"))
        @ref, @path = steps.first(count).join("/"), steps.drop(count).join("/")
        return sha
      rescue DurableAssistants::Github::NotFound
        next
      end
      raise Invalid, repository? ? "#{repo} has no branch, tag or commit called #{steps.first}." : "There is no public repository at github.com/#{repo}."
    rescue DurableAssistants::Github::Error => error
      raise Invalid, error.message
    end

    # Every file in the commit. GitHub cuts a large repository's listing
    # short, so then only a known folder is read, from its own listing; with
    # no folder, or one the cut listing doesn't reach, nothing is guessed.
    def tree(sha)
      listing = DurableAssistants::Github.tree(repo, sha)
      return Array(listing["tree"]) unless listing["truncated"]
      folder = Array(listing["tree"]).find { it["type"] == "tree" && it["path"] == path } if path.present?
      raise Invalid, TOO_LARGE unless folder
      inside = DurableAssistants::Github.tree(repo, folder["sha"])
      raise Invalid, TOO_LARGE if inside["truncated"]
      Array(inside["tree"]).map { it.merge("path" => "#{path}/#{it['path']}") }
    rescue DurableAssistants::Github::Error => error
      raise Invalid, error.message
    end

    # The folder holding the SKILL.md asked for, found as `npx skills` would.
    def locate(blobs)
      folders = blobs.filter_map { File.dirname(it["path"]).then { it == "." ? "" : it } if it["type"] == "blob" && File.basename(it["path"]) == Skill::Folder::MARKDOWN }
      raise Invalid, "#{repo} has no SKILL.md in it, so it holds no skills." if folders.empty?
      usual = folders.select { rank(it) < PLACES.size + 1 }.presence || folders
      if skill
        found = (usual + folders).uniq.select { File.basename(it).casecmp?(skill) || (it.empty? && File.basename(repo).casecmp?(skill)) }
        found.min_by { [ rank(it), it.count("/") ] } or raise Invalid, "#{repo} has no skill called #{skill}. #{listing(usual)}"
      elsif usual.include?("") then ""
      elsif usual.one? then usual.sole
      else raise Invalid, "#{repo} has #{usual.size} skills. Add @ and one's name, as #{repo}@#{File.basename(usual.min)}. #{listing(usual)}"
      end
    end

    # 0 for the top, then each of PLACES in order; anywhere else is last.
    def rank(folder)
      return 0 if folder.empty?
      place = PLACES.index { folder.start_with?("#{it}/") && folder.delete_prefix("#{it}/").count("/") < DEPTH }
      place ? place + 1 : PLACES.size + 1
    end

    def listing(folders)
      names = folders.map { File.basename(it.presence || repo) }.uniq.sort
      "It has #{names.first(20).to_sentence}#{" and #{names.size - 20} more" if names.size > 20}."
    end

    # Refused from the listing, before anything is fetched.
    def check(inside)
      odd = inside.find { it["mode"] == "120000" || it["type"] == "commit" }
      raise Invalid, "#{relative(odd['path'])} is a link or another repository; a skill's files must be real files." if odd
      blobs = inside.select { it["type"] == "blob" }
      raise Invalid, Skill::Folder.too_many(blobs.size - 1) if blobs.size - 1 > Skill::Folder::FILES
      big = blobs.find { it["size"].to_i > Skill::Folder::FILE_BYTES }
      raise Invalid, Skill::Folder.too_big(relative(big["path"])) if big
      raise Invalid, Skill::Folder.too_large if blobs.sum { it["size"].to_i } > Skill::Folder::BYTES
    end

    def entry(blob, sha, known)
      file = relative(blob["path"])
      content = known[blob["sha"]]&.content ||
        DurableAssistants::Github.file(repo, sha, blob["path"], limit: Skill::Folder::FILE_BYTES)
      Skill::Folder::Entry.new(file, content.b, Skill::Folder.executable?(file, content, blob["mode"] == "100755"))
    rescue DurableAssistants::Github::Error => error
      raise Invalid, "#{file} couldn't be fetched: #{error.message}"
    end

    def relative(file) = path.empty? ? file : file.delete_prefix("#{path}/")
end
