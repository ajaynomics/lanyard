import { Controller } from "@hotwired/stimulus"

// A reply that arrives on the open thread is read once in view (Conversation::Standing),
// and so is the thread itself when Rails couldn't read it on opening: a page
// Turbo fetched ahead of the click (ConversationsController#show).
export default class extends Controller {
  static values = { url: String, unseen: Boolean }

  connect() {
    this.unseen = this.unseenValue
    this.observer = new MutationObserver(records => {
      if (records.some(record => [ ...record.addedNodes ].some(node => node.dataset?.role === "assistant"))) this.unseen = true
      this.read()
    })
    this.observer.observe(this.element, { childList: true })
    this.read = this.read.bind(this)
    document.addEventListener("visibilitychange", this.read)
    this.read()
  }

  disconnect() {
    this.observer.disconnect()
    document.removeEventListener("visibilitychange", this.read)
  }

  read() {
    if (!this.unseen || document.visibilityState !== "visible") return
    this.unseen = false
    fetch(this.urlValue, { method: "POST", headers: { "X-CSRF-Token": document.querySelector("meta[name=csrf-token]")?.content } })
  }
}
