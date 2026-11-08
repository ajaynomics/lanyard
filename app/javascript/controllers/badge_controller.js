import { Controller } from "@hotwired/stimulus"

// The installed app's badge (Badging API): agents that need the person (layouts/_badge).
export default class extends Controller {
  static values = { count: Number }

  countValueChanged(count) {
    if ("setAppBadge" in navigator) (count ? navigator.setAppBadge(count) : navigator.clearAppBadge()).catch(() => {})
  }
}
