import { Controller } from "@hotwired/stimulus"
import { clock, day } from "controllers/local_time_controller"

// The thread's times, in the reader's own zone: the day before each day's
// first turn, and the time under the last of each run (one sender's turns,
// each within five minutes of the one before); the newest run's says how long
// ago. Every turn's time holds its full date too, shown on hover or tap
// (layout.css). Redrawn as turns arrive, pages load and each minute passes.
const RUN = 5 * 60 * 1000

export default class extends Controller {
  connect() {
    this.observer = new MutationObserver(() => this.draw())
    this.timer = setInterval(() => this.draw(), 60 * 1000)
    this.draw()
  }

  disconnect() {
    this.observer.disconnect()
    clearInterval(this.timer)
  }

  draw() {
    this.observer.disconnect()
    this.element.querySelectorAll(".ui-time[data-day]").forEach(separator => separator.remove())
    const turns = [ ...this.element.querySelectorAll(".ui-message[data-at]") ]
    turns.forEach((turn, index) => {
      const at = new Date(turn.dataset.at)
      const before = turns[index - 1], after = turns[index + 1]
      if (!before || !sameDay(before, at)) turn.before(separator(at))
      const last = !after || after.dataset.role !== turn.dataset.role || !sameDay(after, at) || new Date(after.dataset.at) - at > RUN
      const time = turn.querySelector(".message__time")
      if (!time) return
      time.toggleAttribute("data-last", last)
      const full = at.toLocaleString(undefined, { dateStyle: "full", timeStyle: "short" })
      time.replaceChildren(span(after ? clock(at) : ago(at)), span(full))
    })
    this.observer.observe(this.element, { childList: true, subtree: true })
  }
}

const sameDay = (turn, at) => new Date(turn.dataset.at).toDateString() === at.toDateString()

const ago = at => {
  const minutes = Math.floor((Date.now() - at) / 60000)
  if (minutes < 1) return "Just now"
  return minutes < 60 ? `${minutes} min ago` : clock(at)
}

const span = text => Object.assign(document.createElement("span"), { textContent: text })

const separator = at => {
  const time = Object.assign(document.createElement("time"), { dateTime: at.toISOString(), textContent: day(at) })
  const line = Object.assign(document.createElement("p"), { className: "ui-time" })
  line.dataset.day = ""
  line.append(time)
  return line
}
