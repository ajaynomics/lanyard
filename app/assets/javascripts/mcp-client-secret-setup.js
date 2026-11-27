// The fragment never reaches the web server or a referrer. Move it into the
// form's filtered POST body, then remove it from the current history entry.
const token = window.location.hash.slice(1)
if (window.location.hash) window.history.replaceState(null, "", window.location.pathname)
if (/^[A-Za-z0-9]{40}$/.test(token)) {
  const form = document.getElementById("client-secret-setup")
  form.elements.setup_token.value = token
  document.getElementById("setup-fields").hidden = false
  document.getElementById("setup-status").textContent = "Enter the client secret. This does not sign in to the connector."
}
