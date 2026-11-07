import { Controller } from "@hotwired/stimulus"

// A flash floats above the page (shadcn: Sonner). A notice goes by itself after
// a few seconds, unless a pointer or focus rests on it; an alert stays until closed.
export default class extends Controller {
  static values = { dismissAfter: Number }

  connect() {
    if (this.dismissAfterValue) this.start()
  }

  start() {
    if (!this.dismissAfterValue) return
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.close(), this.dismissAfterValue)
  }

  pause() {
    clearTimeout(this.timer)
  }

  close() {
    this.element.remove()
  }

  disconnect() {
    clearTimeout(this.timer)
  }
}
