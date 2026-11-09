import { Controller } from "@hotwired/stimulus"

// The prompt cache's minutes where the thread ends (conversations/_usage): warm, about to
// lapse, lapsed, in the words PromptCacheHelper#cache_timer_text uses for the first paint.
export default class extends Controller {
  static values = { until: String, tokens: String, warning: { type: Number, default: 60 } }

  connect() {
    this.tick()
    this.timer = setInterval(() => this.tick(), 10_000)
  }

  disconnect() { clearInterval(this.timer) }

  tick() {
    const left = (Date.parse(this.untilValue) - Date.now()) / 1000
    const minutes = Math.ceil(left / 60)
    const soon = left <= 60 ? "under a minute" : `${minutes} ${minutes === 1 ? "minute" : "minutes"}`
    this.element.dataset.level = left <= 0 ? "over" : left <= this.warningValue ? "near" : "warm"
    this.element.textContent =
      left <= 0 ? `Cache lapsed: your next message reads all ${this.tokensValue} tokens again.`
      : left <= this.warningValue ? `Cache lapses in ${soon}. After that, your next message reads all ${this.tokensValue} tokens again.`
      : `Cache warm for ${minutes} more ${minutes === 1 ? "minute" : "minutes"}.`
    if (left <= 0) clearInterval(this.timer)
  }
}
