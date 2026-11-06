import { Controller } from "@hotwired/stimulus"

// Shows the person's message the moment they send it, with "Working…"
// under it, before the server answers. The echo stays until the committed
// copy of the same words lands in the conversation, then goes; a send that
// fails takes the echo away and puts the words back in the box.
export default class extends Controller {
  static targets = ["message", "working"]

  connect() {
    this.messages = this.element.querySelector("#messages")
    this.observer = new MutationObserver(() => this.retire())
    this.observer.observe(this.messages, { childList: true })
  }

  disconnect() {
    this.observer.disconnect()
  }

  show({ target: form }) {
    if (!form.matches("[data-echo]")) return
    const field = form.querySelector("[name=content]")
    const text = field?.value.trim()
    if (!text) return

    const echo = this.messageTarget.content.firstElementChild.cloneNode(true)
    echo.querySelector(".ui-bubble__text").textContent = text
    // Committed copies of these words already on the page are not this one's.
    echo.dataset.seen = this.sent(text)
    this.messages.querySelector(".chat__empty")?.remove()
    this.messages.append(echo)

    const live = this.element.querySelector(".chat__live")
    if (live && !live.querySelector(".ui-message")) live.append(this.workingTarget.content.firstElementChild.cloneNode(true))

    const typed = field.tagName === "TEXTAREA"
    // The input event lets the box shrink and grow with the words it holds.
    if (typed) refill(field, "")
    form.addEventListener("turbo:submit-end", ({ detail }) => {
      if (detail.success) return
      echo.remove()
      if (typed && !field.value) refill(field, text)
    }, { once: true })
  }

  // One committed copy retires one echo of the same words, oldest first.
  retire() {
    const echoes = [ ...this.messages.querySelectorAll(":scope > [data-pending]") ]
    for (const echo of echoes) {
      if (!echo.isConnected || this.sent(words(echo)) <= Number(echo.dataset.seen)) continue
      echo.remove()
      for (const other of echoes) if (other.isConnected && words(other) === words(echo)) other.dataset.seen = Number(other.dataset.seen) + 1
    }
  }

  sent(text) {
    return [ ...this.messages.querySelectorAll(":scope > [data-role=user]:not([data-pending])") ]
      .filter(message => words(message) === squish(text)).length
  }
}

const refill = (field, value) => {
  field.value = value
  field.dispatchEvent(new Event("input", { bubbles: true }))
}
const squish = text => text.replace(/\s+/g, " ").trim()
const words = element => squish(element.textContent)
