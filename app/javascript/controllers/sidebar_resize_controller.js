import { Controller } from "@hotwired/stimulus"

// The sidebar's edge sets its width: drag, arrow keys; double-click or Home resets.
// A cookie keeps it, so the page is drawn at it (ConversationsHelper#sidebar_width_style).
export default class extends Controller {
  static values = { min: Number, max: Number }

  connect() { this.show() }

  grab(event) {
    if (event.button) return
    event.preventDefault()
    this.element.setPointerCapture(event.pointerId)
    this.left = this.layout.getBoundingClientRect().left
    this.layout.dataset.resizing = ""
  }

  drag(event) {
    if (this.left !== undefined) this.set(event.clientX - this.left)
  }

  release() {
    if (this.left === undefined) return
    this.left = undefined
    delete this.layout.dataset.resizing
    this.save()
  }

  key(event) {
    const step = { ArrowLeft: -16, ArrowRight: 16 }[event.key]
    if (event.key !== "Home" && !step) return
    event.preventDefault()
    if (step) (this.set(this.width + step), this.save())
    else this.reset()
  }

  reset() {
    this.layout.style.removeProperty("--sidebar-width")
    this.save(0)
  }

  set(width) {
    const rem = parseFloat(getComputedStyle(document.documentElement).fontSize)
    this.layout.style.setProperty("--sidebar-width", `${Math.round(Math.min(Math.max(width, this.minValue * rem), this.maxValue * rem))}px`)
    this.show()
  }

  save(age = 31536000) {
    document.cookie = `sidebar_width=${Math.round(this.width)}; path=/; max-age=${age}; samesite=lax`
    this.show()
  }

  show() {
    if (this.width) this.element.setAttribute("aria-valuenow", Math.round(this.width))
  }

  get width() { return this.layout.querySelector(".chat-sidebar").getBoundingClientRect().width }
  get layout() { return this.element.closest(".chat-layout") }
}
