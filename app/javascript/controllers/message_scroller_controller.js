import { Controller } from "@hotwired/stimulus"

// Follows the conversation while the reader is at the live edge, and never
// moves them against their intent: scrolling up releases it, and "Jump to
// latest" (or scrolling back down) takes it again. Content growing is not
// the reader scrolling, so only an upward scroll releases. (shadcn: Message
// Scroller.)
export default class extends Controller {
  static targets = ["viewport", "messages", "jump", "earlier"]

  connect() {
    this.pinned = true
    this.lastTop = 0
    this.onScroll = () => this.update()
    // The thread scrolls in its own box on a wide screen, and as the page itself on a phone (layout.css).
    this.viewportTarget.addEventListener("scroll", this.onScroll, { passive: true })
    window.addEventListener("scroll", this.onScroll, { passive: true })
    this.observer = new MutationObserver(() => this.pinned ? requestAnimationFrame(() => this.scrollToEnd()) : this.update())
    this.observer.observe(this.viewportTarget, { childList: true, subtree: true, characterData: true })
    // The thread opens at its end; only then may an earlier page above load
    // when it comes into view.
    requestAnimationFrame(() => {
      this.scrollToEnd()
      this.opened = true
      this.earlierTargets.forEach(frame => this.earlierTargetConnected(frame))
    })
  }

  earlierTargetConnected(frame) {
    if (this.opened && !frame.src) frame.src = frame.dataset.src
  }

  disconnect() {
    this.viewportTarget.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("scroll", this.onScroll)
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
    const { scrollHeight, scrollTop } = this.scroller
    this.fromEnd = scrollHeight - scrollTop
  }

  restore(event) {
    if (this.fromEnd === undefined || !this.viewportTarget.contains(event.target)) return
    this.scroller.scrollTop = this.scroller.scrollHeight - this.fromEnd
    this.lastTop = this.scroller.scrollTop
    this.fromEnd = undefined
  }

  update() {
    const { scrollTop, scrollHeight, clientHeight } = this.scroller
    const atEnd = scrollHeight - scrollTop - clientHeight < 48
    if (atEnd) this.pinned = true
    else if (scrollTop < this.lastTop - 2) this.pinned = false
    this.lastTop = scrollTop
    this.jumpTarget.hidden = this.pinned || this.latestInView
  }

  // On a phone the pill floats over the foot of the thread. While the latest
  // message shows it has nothing to jump to, and would only cover what lies
  // there: an approval card's buttons, say. A wide screen is unchanged.
  get latestInView() {
    const latest = this.messagesTarget.lastElementChild
    return this.scroller === document.scrollingElement && !!latest &&
      latest.getBoundingClientRect().top < this.jumpTarget.parentElement.getBoundingClientRect().top
  }

  scrollToEnd(behavior = "instant") {
    this.scroller.scrollTo({ top: this.scroller.scrollHeight, behavior })
    this.lastTop = this.scroller.scrollTop
    this.jumpTarget.hidden = true
  }

  get scroller() {
    return getComputedStyle(this.viewportTarget).overflowY === "visible" ? document.scrollingElement : this.viewportTarget
  }
}
