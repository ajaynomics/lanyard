import { Controller } from "@hotwired/stimulus"

// Files attached to the message being written: picked, pasted or dropped.
// Pictures go in the picker's own field (images[]), each a thumbnail made ready
// to send first (pictures.js says how); any other file goes in the files[]
// field, a chip with its name and size. Each has a button to take it off.
export default class extends Controller {
  static targets = ["input", "others", "list"]
  static values = { max: Number, bytes: Number, filesMax: Number, fileBytes: Number }

  connect() {
    this.files = []
    this.others = []
  }

  disconnect() {
    this.forget(this.files)
  }

  pick() {
    this.add([ ...this.inputTarget.files ])
  }

  paste(event) {
    const files = [ ...(event.clipboardData?.files ?? []) ]
    if (!files.length) return
    event.preventDefault()
    this.add(files)
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

  removeOther({ params: { index } }) {
    this.others.splice(index, 1)
    this.sync()
  }

  // Sent: the box empties at once (the echo shows what was attached); a send
  // that fails puts them back, as it does the words.
  sent() {
    this.pending = { files: this.files, others: this.others }
    this.files = []
    this.others = []
    this.sync()
  }

  settled({ detail: { success } }) {
    if (!success && this.pending && !this.files.length && !this.others.length) ({ files: this.files, others: this.others } = this.pending)
    else this.forget(this.pending?.files ?? [])
    this.pending = null
    this.sync()
  }

  add(files) {
    const problems = new Set()
    const adding = []
    const limit = `${Math.round(this.fileBytesValue / 1024 / 1024)} MB`
    for (const file of files) {
      if (!picture(file)) {
        // In the server's own words (Conversation::Attachments).
        if (this.others.length >= this.filesMaxValue) problems.add(`Attach up to ${this.filesMaxValue} files to one message.`)
        else if (file.size > this.fileBytesValue) problems.add(`${file.name} is over ${limit}: each file must be ${limit} or smaller.`)
        else this.others.push(file)
      }
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
    this.inputTarget.files = fileList(this.files.filter(file => !file.preparing))
    this.othersTarget.files = fileList(this.others)
    this.listTarget.replaceChildren(...this.files.map((file, index) => this.thumbnail(file, index)),
      ...this.others.map((file, index) => this.chip(file, index)))
    this.listTarget.hidden = !this.files.length && !this.others.length
  }

  chip(file, index) {
    const element = fileChip(file)
    element.classList.add("composer__file")
    const remove = document.createElement("button")
    remove.type = "button"
    remove.className = "composer__remove"
    remove.textContent = "×"
    remove.title = `Remove ${file.name}`
    remove.setAttribute("aria-label", remove.title)
    remove.dataset.action = "attachments#removeOther"
    remove.dataset.attachmentsIndexParam = index
    element.append(remove)
    return element
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

const fileList = files => {
  const transfer = new DataTransfer()
  files.forEach(file => transfer.items.add(file))
  return transfer.files
}

// A file that is not a picture, as the thread shows it once sent (ui/_files):
// its name and its size, which the echo shows too.
export const fileChip = file => {
  const chip = document.createElement("span")
  chip.className = "ui-files__file"
  chip.innerHTML = '<svg aria-hidden="true" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V7Z"/><path d="M14 2v4a2 2 0 0 0 2 2h4"/></svg>'
  const name = document.createElement("span")
  name.className = "ui-files__name"
  name.textContent = file.name
  const size = document.createElement("span")
  size.className = "ui-files__size"
  size.textContent = humanSize(file.size)
  chip.append(name, size)
  return chip
}

// As Rails' number_to_human_size says it.
const humanSize = bytes => {
  if (bytes < 1024) return `${bytes} Bytes`
  const [ value, unit ] = bytes < 1024 ** 2 ? [ bytes / 1024, "KB" ] : [ bytes / 1024 ** 2, "MB" ]
  return `${Number(value.toPrecision(3))} ${unit}`
}
