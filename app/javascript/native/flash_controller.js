import { Controller } from "@hotwired/stimulus"

// A flash as the phone app's own toast, with a haptic (layouts/_flash): it
// asks Bridge Components' toast and haptic to show it, then hides the page's.
// Only where the app has the toast; elsewhere the page's flash stays.
export default class extends Controller {
  connect() {
    if (!navigator.userAgent.match(/bridge-components: \[[^\]]*\btoast\b/)) return
    // After the bridge's controllers on this element have connected.
    queueMicrotask(() => {
      this.dispatch("show")
      this.element.hidden = true
    })
  }
}
