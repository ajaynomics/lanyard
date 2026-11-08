import { Controller } from "@hotwired/stimulus"

// Follows the conversation while the reader is at the live edge, and never
// moves them against their intent: scrolling up releases it, and "Jump to
// latest" (or scrolling back down) takes it again. Content growing is not
// the reader scrolling, so only an upward scroll releases. (shadcn: Message
// Scroller.)
export default class extends Controller {
  static targets = ["viewport", "jump"]

  connect() {
    this.pinned = true
    this.lastTop = 0
    this.onScroll = () => this.update()
    this.viewportTarget.addEventListener("scroll", this.onScroll, { passive: true })
    this.observer = new MutationObserver(() => { if (this.pinned) requestAnimationFrame(() => this.scrollToEnd()) })
    this.observer.observe(this.viewportTarget, { childList: true, subtree: true, characterData: true })
    requestAnimationFrame(() => this.scrollToEnd())
  }

  disconnect() {
    this.viewportTarget.removeEventListener("scroll", this.onScroll)
    this.observer.disconnect()
  }

  jump() {
    this.pinned = true
    this.scrollToEnd("smooth")
  }

  // An earlier page renders above what the reader sees, so their distance from
  // the end, not from the top, is the place to keep. Browsers that anchor
  // scrolling have kept it already; the rest have not.
  hold(event) {
    if (!this.viewportTarget.contains(event.target)) return
    const { scrollHeight, scrollTop } = this.viewportTarget
    this.fromEnd = scrollHeight - scrollTop
  }

  restore(event) {
    if (this.fromEnd === undefined || !this.viewportTarget.contains(event.target)) return
    this.viewportTarget.scrollTop = this.viewportTarget.scrollHeight - this.fromEnd
    this.lastTop = this.viewportTarget.scrollTop
    this.fromEnd = undefined
  }

  update() {
    const { scrollTop, scrollHeight, clientHeight } = this.viewportTarget
    const atEnd = scrollHeight - scrollTop - clientHeight < 48
    if (atEnd) this.pinned = true
    else if (scrollTop < this.lastTop - 2) this.pinned = false
    this.lastTop = scrollTop
    this.jumpTarget.hidden = this.pinned
  }

  scrollToEnd(behavior = "instant") {
    this.viewportTarget.scrollTo({ top: this.viewportTarget.scrollHeight, behavior })
    this.lastTop = this.viewportTarget.scrollTop
    this.jumpTarget.hidden = true
  }
}
