import { Controller } from "@hotwired/stimulus"

// A <time> in the reader's own zone and words, as Messages writes it:
// "Today 9:41 AM", "Yesterday 9:41 AM", "Tuesday 9:41 AM", "Nov 2, 9:41 AM".
// "short" is a list's (ConversationsHelper#list_time): "now", "4m", "3h", "Tue", "Nov 4", "11/4/25".
export default class extends Controller {
  static values = { format: String }

  connect() {
    this.render()
    if (this.formatValue === "short") this.ticker = setInterval(() => this.render(), 30_000)
  }

  disconnect() { clearInterval(this.ticker) }

  render() {
    const at = new Date(this.element.getAttribute("datetime"))
    if (isNaN(at)) return
    this.element.textContent = this.formatValue === "short" ? short(at) : long(at)
    this.element.title = at.toLocaleString(undefined, { dateStyle: "full", timeStyle: "short" })
  }
}

const DAY = 24 * 60 * 60 * 1000
export const clock = at => at.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
const daysAgo = at => {
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const day = new Date(at)
  day.setHours(0, 0, 0, 0)
  return Math.round((today - day) / DAY)
}
export const day = at => {
  const ago = daysAgo(at)
  if (ago === 0) return "Today"
  if (ago === 1) return "Yesterday"
  if (ago > 1 && ago < 7) return at.toLocaleDateString(undefined, { weekday: "long" })
  const year = at.getFullYear() === new Date().getFullYear() ? undefined : "numeric"
  return at.toLocaleDateString(undefined, { month: "short", day: "numeric", year })
}

const long = at => (daysAgo(at) >= 7 ? `${day(at)}, ${clock(at)}` : `${day(at)} ${clock(at)}`)
const short = at => {
  const m = Math.floor((Date.now() - at) / 6e4), days = daysAgo(at)
  const date = at.getFullYear() === new Date().getFullYear() ? { month: "short", day: "numeric" } : { dateStyle: "short" }
  return m < 1 ? "now" : m < 60 ? `${m}m` : !days ? `${m / 60 | 0}h` : days < 7 ? at.toLocaleDateString(undefined, { weekday: "short" })
    : at.toLocaleDateString(undefined, date)
}
