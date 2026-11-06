import { Controller } from "@hotwired/stimulus"

// Frames of the live reply carry a sequence number and replace the whole tail.
// Broadcasts can arrive out of order, so an older frame is dropped rather than
// shown over a newer one.
export default class extends Controller {
  connect() {
    this.guard = event => {
      const stream = event.target
      if (stream.getAttribute("action") !== "replace") return
      const current = document.getElementById(stream.getAttribute("target"))
      const incoming = stream.templateContent?.firstElementChild
      if (!current?.dataset.seq || !incoming?.dataset.seq) return
      if (Number(incoming.dataset.seq) < Number(current.dataset.seq)) event.preventDefault()
    }
    document.addEventListener("turbo:before-stream-render", this.guard)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.guard)
  }
}
