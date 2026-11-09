import { Controller } from "@hotwired/stimulus"

// The prompt cache's minutes where the thread ends (conversations/_usage): warm, about to
// lapse, lapsed, in the words PromptCacheHelper#cache_timer_text uses for the first paint.
export default class extends Controller {
  static values = { until: String, tokens: String }

  connect() {
    this.tick()
    this.timer = setInterval(() => this.tick(), 10_000)
  }

  disconnect() { clearInterval(this.timer) }

  tick() {
    const left = (Date.parse(this.untilValue) - Date.now()) / 1000
    const minutes = Math.ceil(left / 60)
    this.element.dataset.level = left <= 0 ? "over" : left <= 60 ? "near" : "warm"
    this.element.textContent =
      left <= 0 ? `Cache lapsed: your next message reads all ${this.tokensValue} tokens again.`
      : left <= 60 ? `Cache lapses in under a minute. After that, your next message reads all ${this.tokensValue} tokens again.`
      : `Cache warm for ${minutes} more ${minutes === 1 ? "minute" : "minutes"}.`
    if (left <= 0) clearInterval(this.timer)
  }
}
