import { Controller } from "@hotwired/stimulus"

// Shows the person's message the moment they send it, with "Working…"
// under it, before the server answers. Pictures show from the files being
// sent; the committed copy brings the stored ones. The echo stays until the committed
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

  show({ target: form, detail: { formSubmission } }) {
    if (!form.matches("[data-echo]")) return
    const field = form.querySelector("[name=content]")
    const text = field?.value.trim() ?? ""
    const body = formSubmission?.body
    const pictures = body instanceof FormData ? body.getAll("images[]").filter(file => file instanceof File && file.size) : []
    if (!text && !pictures.length) return

    const echo = this.messageTarget.content.firstElementChild.cloneNode(true)
    echo.querySelector(".ui-bubble__text").textContent = text
    if (!text) echo.querySelector(".ui-bubble").remove()
    if (pictures.length) echo.prepend(previews(pictures))
    // Committed copies of these words already on the page are not this one's.
    // A saved prompt or a skill comes back as other words (Rails expanded it),
    // so its echo goes with the next message of the person's to arrive.
    if (expands(form, text)) {
      echo.dataset.expands = ""
      echo.dataset.seen = this.sent()
    } else {
      echo.dataset.seen = this.sent(text)
    }
    this.messages.querySelector(".chat__empty")?.remove()
    this.messages.append(echo)

    const live = this.element.querySelector(".chat__live")
    if (live && !live.querySelector(".ui-message")) live.append(this.workingTarget.content.firstElementChild.cloneNode(true))

    const typed = field.tagName === "TEXTAREA"
    // The input event lets the box shrink and grow with the words it holds.
    if (typed) refill(field, "")
    form.addEventListener("turbo:submit-end", ({ detail }) => {
      if (detail.success) return
      discard(echo)
      if (typed && !field.value) refill(field, text)
    }, { once: true })
  }

  // One committed copy retires one echo of the same words, oldest first.
  retire() {
    const echoes = [ ...this.messages.querySelectorAll(":scope > [data-pending]") ]
    for (const echo of echoes) {
      const expanded = "expands" in echo.dataset
      if (!echo.isConnected || this.sent(expanded ? undefined : words(echo)) <= Number(echo.dataset.seen)) continue
      discard(echo)
      for (const other of echoes) {
        if (other.isConnected && ("expands" in other.dataset) === expanded && (expanded || words(other) === words(echo))) {
          other.dataset.seen = Number(other.dataset.seen) + 1
        }
      }
    }
  }

  // The person's committed messages on the page: those with these words, or all.
  sent(text) {
    return [ ...this.messages.querySelectorAll(":scope > [data-role=user]:not([data-pending])") ]
      .filter(message => text === undefined || words(message) === squish(text)).length
  }
}

const refill = (field, value) => {
  field.value = value
  field.dispatchEvent(new Event("input", { bubbles: true }))
}
// "/review this" when the bot has a saved prompt called review, or "/skill:x".
const expands = (form, text) => {
  const name = text.match(/^\/(\S+)/)?.[1]
  return Boolean(name && form.querySelector(`[role=option]:is([data-kind=prompt], [data-kind=skill])[data-name="${CSS.escape(name)}"]`))
}
const squish = text => text.replace(/\s+/g, " ").trim()
// The words of a person's message, not its buttons or pictures.
const words = element => squish(element.querySelector(".ui-bubble__text")?.textContent ?? "")

const previews = files => {
  const list = document.createElement("div")
  list.className = "ui-images"
  for (const file of files) {
    const image = document.createElement("img")
    image.className = "ui-images__image ui-images__image--preview"
    image.src = URL.createObjectURL(file)
    image.alt = "Picture you sent"
    list.append(image)
  }
  return list
}

const discard = echo => {
  echo.querySelectorAll("img[src^='blob:']").forEach(image => URL.revokeObjectURL(image.src))
  echo.remove()
}
