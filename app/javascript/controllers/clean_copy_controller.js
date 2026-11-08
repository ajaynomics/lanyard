import { Controller } from "@hotwired/stimulus"

// Copying from the thread gives the words alone: no buttons, times, usage
// lines or bubble colours, whether the selection is inside one bubble or runs
// across several. The browser would otherwise copy the page's styles with the
// text, and a chat app it is pasted into shows them.
const LEAVE_OUT = ".message__actions, .message__usage, .ui-time, .ui-typing, .ui-reasoning > summary, " +
  ".visually-hidden, [aria-hidden=true], button, form, svg, template, script, style"

export default class extends Controller {
  copy(event) {
    const selection = document.getSelection()
    if (!event.clipboardData || !selection || selection.isCollapsed) return
    const words = document.createElement("div")
    for (let index = 0; index < selection.rangeCount; index++) words.append(selection.getRangeAt(index).cloneContents())
    words.querySelectorAll(LEAVE_OUT).forEach(node => node.remove())
    words.querySelectorAll("*").forEach(node => {
      for (const { name } of [ ...node.attributes ]) if (name !== "href") node.removeAttribute(name)
    })

    event.clipboardData.setData("text/html", words.innerHTML)
    event.clipboardData.setData("text/plain", plainText(words))
    event.preventDefault()
  }
}

// Laid out off screen for a moment, so line breaks fall where the page's blocks do.
const plainText = words => {
  words.style.cssText = "position:fixed;left:-10000px;top:0;width:40rem;white-space:normal"
  document.body.append(words)
  const text = words.innerText
  words.remove()
  return text.replace(/\n{3,}/g, "\n\n").trim()
}
