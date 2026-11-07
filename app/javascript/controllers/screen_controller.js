import { Controller } from "@hotwired/stimulus"

// X keysyms for the keys the bar and the phone's keyboard send.
const KEYS = {
  Escape: 0xff1b, Tab: 0xff09, Enter: 0xff0d, Backspace: 0xff08, Delete: 0xffff,
  ArrowLeft: 0xff51, ArrowUp: 0xff52, ArrowRight: 0xff53, ArrowDown: 0xff54,
  Home: 0xff50, End: 0xff57, Control: 0xffe3, Alt: 0xffe9
}
// A character's keysym: Latin-1 as itself, the rest as X's Unicode keysym.
const keysym = character => character === "\n" ? KEYS.Enter : (code => code < 0x100 ? code : 0x1000000 | code)(character.codePointAt(0))

// The conversation's screen through noVNC (vendored, pinned in the importmap). The
// websocket goes to this page's own address; Rails relays it to the conversation's
// Sprite, waking it first, which can take a minute; the page's own status line
// says so until the screen connects. You can watch and type while the conversation
// works. noVNC loads only on this page.
//
// A phone shows its keyboard only for a text box, never for noVNC's canvas, so
// the bar's Keyboard focuses a hidden one and passes what is typed there on as
// keys. Ctrl is held for the next key; Paste types its text in and also puts it
// on the computer's clipboard.
export default class extends Controller {
  static targets = ["display", "status", "keys", "ctrl", "pasteBox", "pasteText"]

  async connect() {
    const { default: RFB } = await import("@novnc/novnc")
    if (!this.element.isConnected) return
    const url = new URL(window.location.href)
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:"
    url.search = ""
    this.rfb = new RFB(this.displayTarget, url.href, { shared: true, wsProtocols: ["binary"] })
    this.rfb.scaleViewport = true
    this.rfb.addEventListener("connect", () => this.say(""))
    this.rfb.addEventListener("disconnect", event => this.say(event.detail.clean ? "The screen closed." : "Couldn't open the screen. Reload to try again."))
  }

  disconnect() {
    this.rfb?.disconnect()
    this.rfb = null
  }

  keyboard() {
    this.keysTarget.focus({ preventScroll: true })
  }

  // A tap on a key leaves the phone's keyboard open.
  keepFocus(event) {
    event.preventDefault()
  }

  toggleCtrl() {
    this.ctrl = !this.ctrl
  }

  press({ params: { key } }) {
    this.send(KEYS[key])
  }

  ctrlAltDel() {
    this.rfb?.sendCtrlAltDel()
  }

  paste(event) {
    event.preventDefault()
    const text = this.pasteTextTarget.value
    if (!text) return
    this.rfb?.clipboardPasteFrom(text)
    for (const character of text.replaceAll("\r\n", "\n")) this.send(keysym(character))
    this.pasteTextTarget.value = ""
    this.pasteBoxTarget.open = false
  }

  // Keys with no text of their own; letters arrive as input instead, which is
  // all a phone's keyboard reliably sends.
  keydown(event) {
    if (event.isComposing || !(event.key in KEYS) || event.key === "Control" || event.key === "Alt") return
    event.preventDefault()
    this.send(KEYS[event.key])
  }

  typed(event) {
    if (event.isComposing) return
    if (event.inputType === "deleteContentBackward") this.send(KEYS.Backspace)
    else if (event.inputType === "insertLineBreak") this.send(KEYS.Enter)
    else for (const character of event.data ?? "") this.send(keysym(character))
    this.keysTarget.value = ""
  }

  composed(event) {
    for (const character of event.data ?? "") this.send(keysym(character))
    this.keysTarget.value = ""
  }

  send(keysym) {
    if (!this.rfb || !keysym) return
    const ctrl = this.ctrl
    if (ctrl) this.rfb.sendKey(KEYS.Control, "ControlLeft", true)
    this.rfb.sendKey(keysym)
    if (ctrl) this.rfb.sendKey(KEYS.Control, "ControlLeft", false)
    this.ctrl = false
  }

  get ctrl() { return this.ctrlTarget.getAttribute("aria-pressed") === "true" }
  set ctrl(held) { this.ctrlTarget.setAttribute("aria-pressed", held) }

  say(text) {
    this.statusTarget.textContent = text
    this.statusTarget.hidden = text === ""
  }
}
