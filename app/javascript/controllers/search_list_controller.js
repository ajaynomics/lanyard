import { Controller } from "@hotwired/stimulus"

// Narrows a list as the person types, on the page, without asking the
// server: an item stays if every word is in its data-search, a group if any
// of its items do. Again after a morph, which shows every item.
export default class extends Controller {
  static targets = ["query", "item", "group", "empty"]

  apply() {
    const words = this.queryTarget.value.toLowerCase().split(/\s+/).filter(Boolean)
    for (const item of this.itemTargets) {
      const text = item.dataset.search.toLowerCase()
      item.hidden = !words.every(word => text.includes(word))
    }
    for (const group of this.groupTargets) {
      group.hidden = words.length > 0 && !this.itemTargets.some(item => !item.hidden && group.contains(item))
    }
    if (this.hasEmptyTarget) this.emptyTarget.hidden = words.length === 0 || this.itemTargets.some(item => !item.hidden)
  }
}
