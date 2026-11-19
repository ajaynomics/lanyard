# Skills

A skill is instructions an agent opens when a task calls for them, in the
[Agent Skills](https://agentskills.io) format that pi and Claude use: a
folder with a `SKILL.md` at its top (YAML frontmatter with `name` and
`description`, then the instructions) and, optionally, files beside it, such
as `references/`, `scripts/` and `assets/`.

The agent's instructions list each ready skill's name and description
(`Agent#skills_listing`). The rest reaches the model only when the agent
calls `read_skill`, or when the person types `/skill:name`. An agent has at
most 32 skills.

## Ways in

All in the agent's Settings, under Skills, then Add a skill. Every way goes
through the same checks (`Skill::Folder`, `Skill.from_markdown`).

- **From GitHub.** `owner/repo@skill-name`, as `npx skills add` takes it, or
  a link to the skill's folder (`https://github.com/owner/repo/tree/<branch>/<folder>`,
  or a link to its `SKILL.md`). Public repositories only; nothing is signed in.
- **From the computer.** A folder, a zip of one, or a `SKILL.md` alone.
- **Typed or pasted.** A name, description and instructions, or a whole
  `SKILL.md` pasted in.

A folder chosen or zipped whole may arrive inside its own name
(`trip/SKILL.md`): that top folder is dropped. What an operating system
leaves (`__MACOSX/`, `.DS_Store`) is ignored.

## Finding a skill on GitHub

`Skill::Github` looks as `npx skills` does (its `discoverSkills`): a
`SKILL.md` at the top makes the repository one skill; otherwise it looks in
`skills/`, `skills/.curated/`, `skills/.experimental/`, `skills/.system/`,
`.agents/skills/`, `data/skills/` and `.claude/skills/`, each three levels
deep, and anywhere else only when those hold none. A skill is the folder that
holds a `SKILL.md`, and `@name` matches the folder's name, which the format
requires to be the skill's. With no `@name`, a repository holding one skill
gives that one; one holding several says their names.

A link's branch may contain slashes, so its first steps are tried, one, two,
three, then four, until one names a commit.

It uses GitHub's public API without a token: the commit a branch names
(`/repos/:repo/commits/:ref`), the commit's whole tree, and each file's
bytes from `raw.githubusercontent.com` at that commit
(`DurableAssistants::Github`). Each request times out after 10 seconds and
each answer is read only up to its limit. Sizes are checked from the tree
before anything is fetched. Unsigned, GitHub allows 60 API calls an hour from
one address; an install or an update uses two or three.

## Pinned, and updated only by a person

A skill from GitHub is pinned to the commit it was fetched at; the skill's
page shows the repository, folder and SHA, linked to that commit. It never
updates itself. **Check for update** asks GitHub where the branch is now
(the default branch, unless a link named another), and shows each file
added, removed or changed since the pinned commit, as a diff. Files whose
git name is unchanged are not fetched again. **Apply update** fetches that
exact commit, replaces the skill's files and pins it there; if either
version has files beside its `SKILL.md`, the skill waits for review again. A new version
that renames the skill is refused: add it as a new skill instead.

## A folder waits for a person

A skill with any file beside its `SKILL.md`, references included, is added
**waiting for review**: any file could be run on the agent's computer, and
no rule can tell which will be. Approval covers the whole folder as read.
Any change asks again: an update that adds, removes, renames or changes a
file, or an edit to its name, description or instructions. A skill that is
its `SKILL.md` alone is ready at once, and its edits stay so. Until a person
approves it, the agent doesn't see it: it is not listed, `read_skill` refuses
it, and `/skill:name` goes as typed.

A file is marked as a program when anything says so: an executable mode (in
a zip, or on GitHub), a `#!` first line, a Linux binary's first bytes, a
script's extension (`.py`, `.sh`, `.js` and the like), or the `scripts/`
folder. The mark is for the reader: it opens the file on the page and words
the warning. It decides nothing about review or readiness.

The skill's page is the review: every file with its size, its contents
highlighted and folded (programs open), and Approve and Reject at the
bottom. Approve carries a digest of what the page showed; if the skill
changed since, nothing is approved and the page says to read it again.
Rejected keeps the skill, unused, until it is removed or approved after all.

Rails never runs a skill's files. It stores them (`skill_bundled_files`),
shows them, and hands them to the agent's computer, where the agent may run
a script as it runs any command there.

## On the agent's computer

When the agent calls `read_skill` and its computer is a Sprite, the call's
answer names the skill's folder, and the sidecar fetches the folder from
Rails once, soon after, as one tar (`POST /agent/files`, as a file a tool
found), and unpacks it at `/home/agent/skills/<name>/`, replacing what was
there, programs still marked as programs (`agent/files.mjs`). The tar is
the version the call answered with, by its digest, read whole in one
transaction; if the skill changed since, or is no longer ready, nothing is
sent. The folder's path is a link to the version last delivered. A version
is named by the digest the skill was approved under, and is published once,
whole: unpacked into a staging folder, checked for its `SKILL.md`, then
renamed to its name. Reading the same version again reuses it; a changed
skill adds a version beside the old. The link moves by renaming a new link
over the old, one delivery at a time per skill, so a reader finds the old
version or the new, never neither. A published version is kept, as a reader
may still be inside it; nothing removes it. A staging folder that fails is
removed, and one a killed delivery left is never used as a version. Each
version is at most the skill's size limit, and only a changed skill adds one. A folder may not hold a file that is also another
file's folder (`a` and `a/b`). The answer
gives `location` (its `SKILL.md`), `folder` and the list of files. The agent
opens a reference only when the skill says to.

`/skill:name` sends pi's skill block with the same location and "References
are relative to" line, and tells the agent to call `read_skill` first to put
the files there.

**Without a computer, or with one that is not a Sprite** (SSH or this
machine), the agent gets the `SKILL.md` alone, with the names of the files it
can't have.

## Limits

- At most 100 files beside `SKILL.md`, 1 MB each and 5 MB in all; a zip of at
  most 5 MB, each entry read only up to 1 MB whatever its header says.
- A path is relative, at most 150 characters, each step at most 100, with no
  `..`, `.`, empty step, backslash, drive letter or control character.
  Links (symlinks) and submodules are refused.
- `SKILL.md`: a name of lowercase letters, digits and single hyphens, up to 64
  characters; a description up to 1,024 characters; instructions up to 32 KB.

## Errors

Each says what is wrong, where the person asked: no `SKILL.md` at the top of
the folder; a `SKILL.md` without a name or description; a path outside the
folder; too many files, a file too large, or a folder too large; a zip that
can't be opened; no public repository there; no such branch, tag or commit;
no skill of that name (with the names it has); several skills and no name; a
repository too large to read whole (link the skill's folder directly; only that folder's own listing is read);
GitHub limiting requests.

## Not built

- Private repositories, and any GitHub sign-in.
- Uploading a new version over an existing skill: remove it and add it again.
- Editing a bundled file in the app. The form edits `SKILL.md`'s name,
  description and instructions; for a skill with files, that asks for
  review again.
- A skill's folder on an SSH or local computer.
