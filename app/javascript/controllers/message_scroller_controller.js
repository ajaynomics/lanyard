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
    this.earlierRenders = new Set()
    this.onScroll = () => this.update()
    // The thread scrolls in its own box on a wide screen, and as the page itself on a phone (layout.css).
    this.viewportTarget.addEventListener("scroll", this.onScroll, { passive: true })
    window.addEventListener("scroll", this.onScroll, { passive: true })
    this.observer = new MutationObserver(() => {
      if (!this.pinned) return this.update()
      // The reader may scroll away before the frame runs.
      requestAnimationFrame(() => { if (this.pinned) this.scrollToEnd() })
    })
    this.observer.observe(this.viewportTarget, { childList: true, subtree: true, characterData: true })
    // The thread also grows with no change to its messages: the phone's text
    // size applied after the page laid out, or a picture loading.
    this.resized = new ResizeObserver(() => { if (this.pinned) this.scrollToEnd() })
    this.resized.observe(this.messagesTarget)
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
    this.resized.disconnect()
  }

  jump() {
    this.pinned = true
    this.scrollToEnd("smooth")
  }

  // An earlier page renders above what the reader sees, so their distance from
  // the end, not from the top, is the place to keep. Browsers that anchor
  // scrolling already do. Hold the first anchor until nested frames finish.
  hold(event) {
    if (!this.viewportTarget.contains(event.target)) return
    const { scrollHeight, scrollTop } = this.scroller
    if (this.earlierRenders.size === 0) this.fromEnd = scrollHeight - scrollTop
    this.earlierRenders.add(event.target)
  }

  restore(event) {
    if (!this.earlierRenders.delete(event.target)) return
    this.scroller.scrollTop = this.scroller.scrollHeight - this.fromEnd
    this.lastTop = this.scroller.scrollTop
  }

  update() {
    const { scrollTop, scrollHeight, clientHeight } = this.scroller
    const atEnd = scrollHeight - scrollTop - clientHeight < 48
    if (atEnd) this.pinned = true
    else if (scrollTop < this.lastTop - 2) this.pinned = false
    this.lastTop = scrollTop
    this.jumpTarget.hidden = this.pinned || this.latestInView
  }

  // The pill floats over the foot of the thread. While the latest message
  // shows it has nothing to jump to, and would only cover what lies there: an
  // approval card's buttons, say. The foot is where what scrolls ends, the
  // page's on a phone and the thread's own box on a wide screen.
  get latestInView() {
    const latest = this.messagesTarget.lastElementChild
    return !!latest && latest.getBoundingClientRect().top < this.jumpTarget.parentElement.getBoundingClientRect().top
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
