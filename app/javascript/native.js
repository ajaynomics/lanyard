// The phone app's bridge (docs/native-app.md), loaded only inside the app
// (layouts/application). Each controller hands a piece of the page to the app,
// which draws it natively: Bridge Components' (bridge--*) for the bar's
// buttons, menus, form submits, toasts, haptics, sharing, confirmations and
// notification tokens, and the app's own (native--*) for what they lack. A
// controller whose component the app doesn't have never loads, so the page's
// own control stays (layout.css).
import { Turbo } from "@hotwired/turbo-rails"
import { application } from "controllers/application"
import { controllers } from "@joemasilotti/bridge-components"
import ApprovalController from "native/approval_controller"
import FlashController from "native/flash_controller"
import LocationRequestController from "native/location_request_controller"
import PushDeviceController from "native/push_device_controller"
import SearchController from "native/search_controller"
import SessionController from "native/session_controller"
import TabBadgeController from "native/tab_badge_controller"

application.load(controllers)
application.register("native--approval", ApprovalController)
application.register("native--flash", FlashController)
application.register("bridge--phone-location", LocationRequestController)
application.register("native--push-device", PushDeviceController)
application.register("native--search", SearchController)
application.register("native--session", SessionController)
application.register("native--tab-badge", TabBadgeController)

// data-turbo-confirm asks with iOS's own alert (Bridge Components' alert),
// its button named as the one pressed, in red: what asks is what removes.
// Cancel sends no answer, so the form simply never goes. Without the
// component, the page's own dialog asks, as in a browser (application.js).
const webConfirm = Turbo.config.forms.confirm
Turbo.config.forms.confirm = (message, element, submitter) => {
  const bridge = window.HotwireNative?.web
  if (!bridge?.supportsComponent("alert")) return webConfirm(message, element, submitter)
  return new Promise(resolve => {
    bridge.send({ component: "alert", event: "show", callback: () => resolve(true), data: {
      title: message, destructive: true, metadata: { url: window.location.href },
      confirm: submitter?.textContent?.trim() || "Continue", dismiss: submitter?.dataset?.confirmDismiss || "Cancel"
    } })
  })
}

// The keyboard covers the foot of the web view without shrinking its layout,
// so the composer, stuck to the foot, would sit under it: it rises by as much
// as the keyboard covers (layout.css, --keyboard-inset).
const viewport = window.visualViewport
if (viewport) {
  const follow = () => {
    const covered = Math.max(0, window.innerHeight - viewport.height - viewport.offsetTop)
    document.documentElement.style.setProperty("--keyboard-inset", `${Math.round(covered)}px`)
  }
  viewport.addEventListener("resize", follow)
  viewport.addEventListener("scroll", follow)
}
