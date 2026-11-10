// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import { Turbo } from "@hotwired/turbo-rails"
import "controllers"

// The PWA's service worker (app/views/pwa/service-worker.js): installable, and
// an offline page instead of the browser's error.
if ("serviceWorker" in navigator) navigator.serviceWorker.register("/service-worker", { scope: "/" })

// data-turbo-confirm asks in a native <dialog> (layouts/_confirm), not the
// browser's confirm(): it looks like the app, and Escape or Cancel says no.
// Its button reads as the one that was pressed: "Remove", "Disconnect".
Turbo.config.forms.confirm = (message, _element, submitter) => {
  const dialog = document.getElementById("confirm")
  if (!dialog?.showModal) return Promise.resolve(window.confirm(message))
  dialog.querySelector("#confirm_title").textContent = message
  dialog.querySelector("#confirm_accept").textContent = submitter?.textContent?.trim() || "Continue"
  dialog.returnValue = ""
  dialog.showModal()
  return new Promise(resolve => dialog.addEventListener("close", () => resolve(dialog.returnValue === "confirm"), { once: true }))
}

// A link up a level (the bar's way back, data-up) slides the page back, as
// history's back does, not on as a link does.
document.addEventListener("turbo:click", event => {
  document.documentElement.toggleAttribute("data-going-up", Boolean(event.target.closest("[data-up]")))
})

// A morph leaves the text box being typed in as it is (docs/design.md, "Typing survives").
document.addEventListener("turbo:before-morph-attribute", event => {
  const { target, detail: { attributeName } } = event
  if (attributeName === "value" && target instanceof HTMLTextAreaElement && target === document.activeElement) event.preventDefault()
})
