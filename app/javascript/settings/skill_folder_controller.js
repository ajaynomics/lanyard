import { Controller } from "@hotwired/stimulus"

// A chosen folder's files arrive under their own names alone, so each
// file's path inside the folder goes beside it, in the same order
// (Skill::Folder.from_uploads).
export default class extends Controller {
  static targets = [ "folder" ]

  choose() {
    this.element.querySelectorAll("input[data-skill-folder-path]").forEach(input => input.remove())
    for (const file of this.folderTarget.files) {
      const input = document.createElement("input")
      input.type = "hidden"
      input.name = "skill[paths][]"
      input.value = file.webkitRelativePath || file.name
      input.dataset.skillFolderPath = ""
      this.element.append(input)
    }
  }
}
