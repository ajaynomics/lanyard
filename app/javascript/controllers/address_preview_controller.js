import { Controller } from "@hotwired/stimulus"

// New agent: as the name is typed, the frame under it asks the server for the
// address the agent would get, since only the server knows which are taken.
export default class extends Controller {
  static targets = [ "name", "frame" ]
  static values = { url: String }

  disconnect() { clearTimeout(this.timer) }

  preview() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      const url = new URL(this.urlValue, window.location.href)
      url.searchParams.set("name", this.nameTarget.value)
      this.frameTarget.src = url.toString()
    }, 250)
  }
}
