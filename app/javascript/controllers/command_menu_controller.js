import { Controller } from "@hotwired/stimulus"

// The list under "/" in the composer: the built-in commands, the agent's saved
// prompts and skills, and after "/model " or "/thinking " their choices.
// Rails renders every item (conversations/_command_menu); this only shows the
// ones that match what is typed.
//
// Typing "/" at the start, before any space, opens it. The arrows move, Tab
// (or a tap, on a phone) completes the highlighted item with a space after
// it, and Esc closes it until the text changes. It never handles Enter:
// Enter sends what is typed (composer_controller), so the list cannot change
// what a person meant to send.
export default class extends Controller {
  static targets = ["input", "list", "option"]

  update() {
    const text = this.inputTarget.value
    const query = queryOf(text)
    if (!query || text === this.dismissed) return this.close()
    this.dismissed = null
    const shown = this.optionTargets.filter(option => {
      option.hidden = !matches(option, query)
      return !option.hidden
    })
    shown.length ? this.open(shown) : this.close()
  }

  navigate(event) {
    if (!this.isOpen || event.isComposing) return
    switch (event.key) {
      case "ArrowDown": return this.move(event, 1)
      case "ArrowUp": return this.move(event, -1)
      case "Tab":
        if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return
        event.preventDefault()
        return this.complete(this.active)
      case "Escape":
        event.preventDefault()
        this.dismissed = this.inputTarget.value
        return this.close()
    }
  }

  // Keeps the focus (and a phone's keyboard) in the box when an item is tapped.
  hold(event) {
    event.preventDefault()
  }

  pick(event) {
    this.complete(event.currentTarget)
  }

  close() {
    if (!this.hasListTarget) return
    this.listTarget.hidden = true
    this.inputTarget.setAttribute("aria-expanded", "false")
    this.inputTarget.removeAttribute("aria-activedescendant")
  }

  open(shown) {
    this.listTarget.hidden = false
    this.inputTarget.setAttribute("aria-expanded", "true")
    this.select(shown.includes(this.active) ? this.active : shown[0])
  }

  move(event, step) {
    event.preventDefault()
    const shown = this.shown
    const index = shown.indexOf(this.active)
    this.select(shown[(index + step + shown.length) % shown.length])
  }

  select(option) {
    for (const each of this.optionTargets) each.setAttribute("aria-selected", each === option ? "true" : "false")
    this.inputTarget.setAttribute("aria-activedescendant", option.id)
    option.scrollIntoView({ block: "nearest" })
  }

  complete(option) {
    if (!option) return
    const { kind, name, command } = option.dataset
    const text = kind === "argument" ? `/${command} ${name} ` : `/${name} `
    this.inputTarget.value = text
    this.inputTarget.focus()
    this.inputTarget.setSelectionRange(text.length, text.length)
    // The box resizes and keeps its draft, and the list follows: "/model "
    // offers the models next.
    this.inputTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  get isOpen() {
    return this.hasListTarget && !this.listTarget.hidden
  }

  get shown() {
    return this.optionTargets.filter(option => !option.hidden)
  }

  get active() {
    return this.optionTargets.find(option => option.getAttribute("aria-selected") === "true" && !option.hidden)
  }
}

// "/na" asks for a name; "/model cl" for one of /model's choices.
const queryOf = text => {
  let match = text.match(/^\/(\S*)$/)
  if (match) return { term: match[1].toLowerCase() }
  match = text.match(/^\/(\S+) (\S*)$/)
  if (match) return { command: match[1], term: match[2].toLowerCase() }
}

const matches = (option, { command, term }) => {
  const { kind, name, hint } = option.dataset
  if (command) return kind === "argument" && option.dataset.command === command && `${name} ${hint}`.toLowerCase().includes(term)
  return kind !== "argument" && (name.startsWith(term) || name.replace(/^skill:/, "").startsWith(term))
}
