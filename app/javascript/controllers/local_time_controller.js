import { Controller } from "@hotwired/stimulus"

// A <time> in the reader's own zone and words, as Messages writes it:
// "Today 9:41 AM", "Yesterday 9:41 AM", "Tuesday 9:41 AM", "Nov 2, 9:41 AM".
// "short" is a list's: "9:41 AM", "Yesterday", "Tuesday", "Nov 2".
export default class extends Controller {
  static values = { format: String }

  connect() {
    const at = new Date(this.element.getAttribute("datetime"))
    if (isNaN(at)) return
    this.element.textContent = this.formatValue === "short" ? short(at) : long(at)
    this.element.title = at.toLocaleString(undefined, { dateStyle: "full", timeStyle: "short" })
  }
}

const DAY = 24 * 60 * 60 * 1000
const clock = at => at.toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" })
const daysAgo = at => {
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const day = new Date(at)
  day.setHours(0, 0, 0, 0)
  return Math.round((today - day) / DAY)
}
const day = at => {
  const ago = daysAgo(at)
  if (ago === 0) return "Today"
  if (ago === 1) return "Yesterday"
  if (ago > 1 && ago < 7) return at.toLocaleDateString(undefined, { weekday: "long" })
  const year = at.getFullYear() === new Date().getFullYear() ? undefined : "numeric"
  return at.toLocaleDateString(undefined, { month: "short", day: "numeric", year })
}

const long = at => (daysAgo(at) >= 7 ? `${day(at)}, ${clock(at)}` : `${day(at)} ${clock(at)}`)
const short = at => (daysAgo(at) === 0 ? clock(at) : day(at))
