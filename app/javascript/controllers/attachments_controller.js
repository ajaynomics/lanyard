import { Controller } from "@hotwired/stimulus"

// Pictures attached to the message being written: picked, pasted or dropped.
// The file field holds them; each is a thumbnail with a button to take it off,
// made ready to send first (pictures.js says how).
export default class extends Controller {
  static targets = ["input", "list"]
  static values = { max: Number, bytes: Number }

  connect() {
    this.files = []
  }

  disconnect() {
    this.forget(this.files)
  }

  pick() {
    this.add([ ...this.inputTarget.files ])
  }

  paste(event) {
    const pictures = [ ...(event.clipboardData?.files ?? []) ].filter(picture)
    if (!pictures.length) return
    event.preventDefault()
    this.add(pictures)
  }

  over(event) {
    if (![ ...(event.dataTransfer?.types ?? []) ].includes("Files")) return
    event.preventDefault()
    this.element.dataset.dragging = ""
  }

  leave() {
    delete this.element.dataset.dragging
  }

  drop(event) {
    this.leave()
    if (!event.dataTransfer?.files.length) return
    event.preventDefault()
    this.add([ ...event.dataTransfer.files ])
  }

  remove({ params: { index } }) {
    this.forget(this.files.splice(index, 1))
    this.sync()
  }

  // Sent: the box empties at once (the echo shows the pictures); a send that
  // fails puts them back, as it does the words.
  sent() {
    this.pending = this.files
    this.files = []
    this.sync()
  }

  settled({ detail: { success } }) {
    if (!success && this.pending && !this.files.length) this.files = this.pending
    else this.forget(this.pending ?? [])
    this.pending = null
    this.sync()
  }

  add(files) {
    const problems = new Set()
    const adding = []
    for (const file of files) {
      if (!picture(file)) problems.add("Only pictures can be attached.")
      else if (this.files.length >= this.maxValue) problems.add(`Attach up to ${this.maxValue} pictures to one message.`)
      else adding.push(Object.assign(file, { preview: URL.createObjectURL(file), preparing: true }))
    }
    this.files.push(...adding)
    this.say([ ...problems ].join(" "))
    this.sync()
    adding.forEach(file => this.prepare(file))
  }

  async prepare(file) {
    try {
      const { prepare } = await import("pictures")
      const ready = await prepare(file, this.bytesValue)
      this.swap(file, ready === file ? Object.assign(file, { preparing: false }) : Object.assign(ready, { preview: URL.createObjectURL(ready) }))
    } catch (error) {
      this.swap(file, null)
      this.say(error.message)
    }
  }

  swap(before, after) {
    const index = this.files.indexOf(before)
    if (index < 0) return
    if (after !== before) this.forget([ before ])
    this.files.splice(index, 1, ...(after ? [ after ] : []))
    this.sync()
  }

  hold(event) {
    if (!this.files.some(file => file.preparing)) return
    event.preventDefault()
    event.stopImmediatePropagation()
    this.say("Preparing your pictures: send again in a moment.")
  }

  sync() {
    const transfer = new DataTransfer()
    this.files.filter(file => !file.preparing).forEach(file => transfer.items.add(file))
    this.inputTarget.files = transfer.files
    this.listTarget.replaceChildren(...this.files.map((file, index) => this.thumbnail(file, index)))
    this.listTarget.hidden = !this.files.length
  }

  thumbnail(file, index) {
    const figure = document.createElement("figure")
    figure.className = "composer__thumb"
    if (file.preparing) {
      figure.dataset.preparing = ""
      figure.setAttribute("aria-busy", "true")
      const note = document.createElement("figcaption")
      note.textContent = "Preparing…"
      figure.append(note)
    }
    const link = document.createElement("a")
    link.href = file.preview
    link.target = "_blank"
    link.title = `Open ${file.name || "picture"} full size`
    const image = document.createElement("img")
    image.src = file.preview
    image.alt = file.name || "Attached picture"
    link.append(image)
    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "composer__remove"
    remove.textContent = "×"
    remove.title = `Remove ${file.name || "picture"}`
    remove.setAttribute("aria-label", remove.title)
    remove.dataset.action = "attachments#remove"
    remove.dataset.attachmentsIndexParam = index
    figure.append(link, remove)
    return figure
  }

  say(text) {
    const error = this.element.querySelector("#composer_error")
    if (error) error.textContent = text
  }

  forget(files) {
    files.forEach(file => file.preview && URL.revokeObjectURL(file.preview))
  }
}

const picture = file => file.type.startsWith("image/")
