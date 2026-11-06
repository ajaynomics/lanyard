import { Controller } from "@hotwired/stimulus"

// Keeps broadcasts honest when they arrive out of order:
// - frames of the live reply carry a sequence number and replace the whole
//   tail, so an older frame is dropped rather than shown over a newer one;
// - messages carry their entry id, so one appended late takes its place in
//   the conversation instead of landing at the end;
// - the live reply is morphed in place, and a thinking panel the person opened
//   or closed stays that way while the reply streams, as does a tool line
//   whose result arrives.
export default class extends Controller {
  connect() {
    this.guard = event => {
      const stream = event.target
      const action = stream.getAttribute("action")
      const current = document.getElementById(stream.getAttribute("target"))
      if (action === "replace") {
        const incoming = stream.templateContent?.firstElementChild
        if (current?.dataset.seq && incoming?.dataset.seq && Number(incoming.dataset.seq) < Number(current.dataset.seq)) event.preventDefault()
      } else if (action === "append" && current?.id === "messages") {
        const render = event.detail.render
        event.detail.render = async element => { await render(element); this.order(current) }
      }
    }
    document.addEventListener("turbo:before-stream-render", this.guard)

    this.toggled = event => {
      const panel = event.target.closest("details > summary")?.parentElement
      if (panel) panel.dataset.toggled = "true"
    }
    this.keep = event => {
      if (event.target.dataset?.toggled && [ "open", "data-toggled" ].includes(event.detail.attributeName)) event.preventDefault()
    }
    this.element.addEventListener("click", this.toggled)
    document.addEventListener("turbo:before-morph-attribute", this.keep)
  }

  disconnect() {
    document.removeEventListener("turbo:before-stream-render", this.guard)
    this.element.removeEventListener("click", this.toggled)
    document.removeEventListener("turbo:before-morph-attribute", this.keep)
  }

  order(list) {
    const entries = [...list.children].filter(child => child.dataset.entryId)
    const sorted = [...entries].sort((a, b) => Number(a.dataset.entryId) - Number(b.dataset.entryId))
    if (sorted.every((child, index) => child === entries[index])) return
    for (const child of sorted) list.append(child)
  }
}
