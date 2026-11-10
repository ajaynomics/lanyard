import { Controller } from "@hotwired/stimulus"

// The agents list as a side panel on a narrow screen (shadcn: Sheet), in a
// modal <dialog>. It slides by data-shown, so closing animates in Safari too
// before the dialog leaves; Esc, the backdrop, a swipe and a choice close it.
export default class extends Controller {
  static targets = ["dialog"]

  // Focus on the open agent, not the search box, which would raise a phone's keyboard.
  open() {
    const dialog = this.dialogTarget
    if (dialog.open) return
    dialog.showModal()
    dialog.querySelector("[aria-current=page]")?.focus()
    dialog.getBoundingClientRect()
    dialog.dataset.shown = ""
  }

  closeOnBackdrop(event) {
    if (event.target === this.dialogTarget && !this.swiped) this.close()
  }

  cancel(event) {
    event.preventDefault()
    this.close()
  }

  // Reading the style starts the slide, so Safari lists it; one that never ends still lets the dialog go.
  async close() {
    const dialog = this.dialogTarget
    if (!dialog.open || !("shown" in dialog.dataset)) return
    delete dialog.dataset.shown
    dialog.style.translate = ""
    getComputedStyle(dialog).translate
    await Promise.race([Promise.allSettled(dialog.getAnimations().map(it => it.finished)), new Promise(done => setTimeout(done, 300))])
    if (!("shown" in dialog.dataset)) dialog.close()
  }

  closeNow() {
    const dialog = this.dialogTarget
    delete dialog.dataset.shown
    dialog.style.translate = ""
    if (dialog.open) dialog.close()
  }

  // A swipe toward the edge follows the finger and closes past a third; less springs back.
  grab(event) {
    if (event.pointerType === "mouse" || !this.dialogTarget.open) return
    this.swipe = { x: event.clientX, y: event.clientY, dx: 0 }
    this.swiped = false
  }

  drag(event) {
    if (!this.swipe) return
    const dx = Math.min(0, event.clientX - this.swipe.x)
    if (!this.swiped && Math.abs(event.clientY - this.swipe.y) > Math.abs(dx)) return (this.swipe = null)
    this.swipe.dx = dx
    this.swiped ||= dx < -8
    if (!this.swiped) return
    this.dialogTarget.dataset.dragging = ""
    this.dialogTarget.style.translate = `${dx}px 0`
  }

  release() {
    if (!this.swipe) return
    const far = this.swipe.dx < -this.dialogTarget.offsetWidth / 3
    this.swipe = null
    delete this.dialogTarget.dataset.dragging
    far ? this.close() : (this.dialogTarget.style.translate = "")
    setTimeout(() => (this.swiped = false))
  }
}
