// Keep the token out of HTTP URLs and remove it from this history entry.
async function takeStartToken() {
  if (!window.location.hash) return
  const token = window.location.hash.slice(1)
  window.history.replaceState(null, "", window.location.pathname)

  const form = document.getElementById("google-account-start-form")
  const field = form.elements.start_token
  const button = document.getElementById("google-account-start-submit")
  const status = document.getElementById("google-account-start-status")
  const valid = /^[A-Za-z0-9]{40}$/.test(token)
  field.value = valid ? token : ""
  button.hidden = true
  const failedPreview = "Could not check this link. Open it again to retry."
  if (!valid) {
    status.textContent = failedPreview
    return
  }

  try {
    const body = new URLSearchParams(new FormData(form))
    body.set("preview", "1")
    const response = await fetch(form.action, {
      method: "POST", headers: { Accept: "text/plain" }, body, mode: "same-origin", redirect: "error"
    })
    if (!response.ok) throw new Error("Could not preview link")
    const agentName = await response.text()
    if (field.value !== token) return
    status.textContent = agentName
      ? `This lets ${agentName} search the Gmail account you pick; it cannot send or draft mail.`
      : "Continue to Google and choose the account you were asked to connect."
    button.hidden = false
  } catch {
    if (field.value === token) status.textContent = failedPreview
  }
}

takeStartToken()
window.addEventListener("hashchange", takeStartToken)
