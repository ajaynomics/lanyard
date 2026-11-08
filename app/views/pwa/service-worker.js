// Installable and honest offline: pages always come from the network (a
// conversation is never served stale), and only a failed navigation gets a
// small offline page. Live updates (Action Cable) and forms never touch this.
const OFFLINE = new Response(
  "<!doctype html><meta name=viewport content='width=device-width'><title>Offline</title>" +
  "<body style='font-family:system-ui;padding:2rem'><h1>You are offline</h1><p>This app needs a connection. Try again when you are back online.</p>",
  { headers: { "Content-Type": "text/html; charset=utf-8" } }
)

self.addEventListener("install", () => self.skipWaiting())
self.addEventListener("activate", event => event.waitUntil(self.clients.claim()))

self.addEventListener("fetch", event => {
  if (event.request.mode !== "navigate") return
  event.respondWith(fetch(event.request).catch(() => OFFLINE.clone()))
})

// Notifications (docs/design.md, "Notifications, badge and sharing"). Rails
// decides when to send one (Conversation::Notifiable); a notice is
// { kind, title, body, url, tag, badge }, one tag per thread, so a newer
// notice replaces an older one.
//
// Whether to show it is decided here, not in Rails: only the device knows
// whether a window is in front and on the thread. A reply already on the
// screen the person is looking at needs no notice. An agent that needs the
// person always gets one, since its card may be out of view.
function shouldShow(notice, windows) {
  if (notice.kind !== "reply") return true
  return !windows.some(client => client.focused && new URL(client.url).pathname === notice.url)
}

self.addEventListener("push", event => {
  const notice = event.data?.json() ?? {}
  event.waitUntil((async () => {
    // The app's badge: how many agents need the person. Where there is one.
    if ("setAppBadge" in self.navigator) {
      await (notice.badge ? self.navigator.setAppBadge(notice.badge) : self.navigator.clearAppBadge()).catch(() => {})
    }
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true })
    if (!shouldShow(notice, windows)) return
    await self.registration.showNotification(notice.title ?? "", {
      body: notice.body, tag: notice.tag, data: { url: notice.url }, icon: "/icons/app-192.png"
    })
  })())
})

// Opens the thread: the window already on it, or a new one.
self.addEventListener("notificationclick", event => {
  event.notification.close()
  const url = new URL(event.notification.data?.url ?? "/", self.location.origin)
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true })
    const open = windows.find(client => new URL(client.url).pathname === url.pathname)
    return open ? open.focus() : self.clients.openWindow(url.href)
  })())
})
