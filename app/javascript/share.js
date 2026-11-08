// Pictures shared from another app (SharesController), loaded only on the
// composer that holds some (conversations/_composer), so a thread's first
// load does not carry it. They are attached as if picked: through the
// composer's own attachments controller and its checks, reached as an
// outlet, so whichever of the two connects first, they meet.
import { Controller } from "@hotwired/stimulus"
import { application } from "controllers/application"

application.register("shared-pictures", class extends Controller {
  static outlets = [ "attachments" ]
  static values = { files: Array }

  async attachmentsOutletConnected(attachments) {
    if (this.attached) return
    this.attached = true
    try {
      attachments.add(await Promise.all(this.filesValue.map(async ({ url, name }) => {
        const response = await fetch(url)
        if (!response.ok) throw new Error(response.statusText)
        const blob = await response.blob()
        return new File([ blob ], name, { type: blob.type })
      })))
    } catch {
      attachments.say("The shared pictures couldn't be attached. Share them again.")
    }
  }
})
