import { Controller } from "@hotwired/stimulus"

// Enter sends; Shift+Enter (or Enter while an input method is composing)
// makes a new line. While the agent works, Enter steers it (the Steer button
// shows then). The box grows with its text. (shadcn: Prompt Input.)
//
// Sending is always what is typed. A built-in command (/new, /stop, …) goes
// through its own form, which Rails rendered with the list; anything else,
// a saved prompt or a skill included, is a message that Rails expands. The
// command list (command_menu_controller) only completes; it never sends.
//
// Up in an empty box brings back the last message sent, as in pi. What is
// typed is kept per conversation in localStorage (draft:<id>) until it is sent.
export default class extends Controller {
  static targets = ["input", "steer"]
  static values = { draftKey: String }

  connect() {
    // A phone has room for "Message" and not the agent's name after it.
    if (matchMedia("(max-width: 30rem)").matches) this.inputTarget.placeholder = "Message"
    const draft = this.draftKeyValue && localStorage.getItem(this.draftKeyValue)
    if (draft && !this.inputTarget.value) this.inputTarget.value = draft
    this.resize()
  }

  submitOnEnter(event) {
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return
    event.preventDefault()
    // Once: a message on its way is not sent again by a second Enter.
    if (this.empty || this.element.hasAttribute("aria-busy")) return
    this.element.requestSubmit(this.hasSteerTarget && this.steerTarget.checkVisibility() ? this.steerTarget : null)
  }

  // Words, pictures or both; not nothing. A built-in command never goes as a
  // message, whichever way it was sent (Enter or the Send button).
  send(event) {
    if (this.empty || this.runCommand()) return event.preventDefault()
    this.lastSent = this.inputTarget.value.trim()
  }

  recall(event) {
    const box = this.inputTarget
    if (event.key !== "ArrowUp" || event.defaultPrevented || box.value || box.selectionStart !== 0) return
    const text = this.lastSent ?? lastMessage()
    if (!text) return
    event.preventDefault()
    this.fill(text)
    box.setSelectionRange(text.length, text.length)
  }

  keepDraft() {
    if (!this.draftKeyValue) return
    const text = this.inputTarget.value
    text.trim() ? localStorage.setItem(this.draftKeyValue, text) : localStorage.removeItem(this.draftKeyValue)
  }

  get empty() {
    return !this.inputTarget.value.trim() && !this.element.querySelector("input[type=file]")?.files.length
  }

  resize() {
    this.inputTarget.style.height = "auto"
    this.inputTarget.style.height = `${Math.min(this.inputTarget.scrollHeight, 240)}px`
  }

  // Runs the built-in the text names, and says whether there was one.
  runCommand() {
    const [ , name, rest ] = this.inputTarget.value.trim().match(/^\/(\S+)(?:\s+([\s\S]*))?$/) ?? []
    const command = name && this.element.querySelector(`[role=option][data-kind=command][data-name="${CSS.escape(name)}"]`)
    if (!command) return false
    const argument = (rest ?? "").trim()
    const problem = command.dataset.run ? this.run(command.dataset.run) : this.submitCommand(command, argument)
    this.say(problem ?? "")
    if (!problem) {
      this.lastSent = this.inputTarget.value.trim()
      this.fill("")
    }
    return true
  }

  // Fills in the command's form and sends it; a reason when it cannot.
  submitCommand(command, argument) {
    if (command.dataset.missing && !argument) return command.dataset.missing
    const form = document.getElementById(command.dataset.form)
    const field = form.querySelector("[data-command-argument]")
    if (field) field.value = argument
    const answer = form.querySelector("[data-command-answer]")
    if (answer) {
      const replies = document.querySelectorAll("#messages [data-answer-id]")
      if (!replies.length) return "There is no reply to branch from yet."
      answer.value = replies[replies.length - 1].dataset.answerId
    }
    form.requestSubmit()
  }

  run(action) {
    if (action === "help") {
      document.getElementById("help_dialog")?.showModal()
    } else if (action === "copy") {
      const buttons = document.querySelectorAll("#messages [data-copy-reply]")
      if (!buttons.length) return "There is no reply to copy yet."
      buttons[buttons.length - 1].click()
    }
  }

  fill(text) {
    this.inputTarget.value = text
    this.inputTarget.dispatchEvent(new Event("input", { bubbles: true }))
  }

  say(text) {
    const error = this.element.querySelector("#composer_error")
    if (error) error.textContent = text
  }
}

// The person's newest message on the page, as they typed it.
const lastMessage = () => {
  const messages = document.querySelectorAll("#messages > [data-role=user]")
  const message = messages[messages.length - 1]
  return message?.dataset.typed ?? message?.querySelector(".ui-bubble__text")?.textContent.trim()
}
