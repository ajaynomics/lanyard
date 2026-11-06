import { Controller } from "@hotwired/stimulus"

// Offers only the thinking levels the chosen model supports. Each model
// option carries its levels (pi-ai's, through the sidecar) as
// data-thinking-levels: [[label, value], …]. The level chosen before is kept
// when the new model has it; otherwise Medium, or the model's first.
export default class extends Controller {
  static targets = ["model", "level"]

  offer() {
    const option = this.modelTarget.selectedOptions[0]
    const levels = JSON.parse(option?.dataset.thinkingLevels || "[]")
    if (!levels.length) return
    const values = levels.map(([, value]) => value)
    const previous = this.levelTarget.value
    const chosen = values.includes(previous) ? previous : values.includes("medium") ? "medium" : values[0]
    this.levelTarget.replaceChildren(...levels.map(([label, value]) => new Option(label, value, false, value === chosen)))
  }
}
