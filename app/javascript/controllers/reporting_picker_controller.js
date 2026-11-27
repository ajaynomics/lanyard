import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  static targets = ["preview"]
  static values = { agent: Number }

  connect() { this.element.showModal() }

  preview(event) {
    if (event.target.dataset.preview) this.previewTarget.textContent = event.target.dataset.preview
  }

  close() { this.element.close() }

  restore() {
    document.getElementById(`reporting_actions_agent_${this.agentValue}`)?.focus()
  }
}
