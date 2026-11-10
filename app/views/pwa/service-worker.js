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
// Every push shows a notification, whatever it holds: a push with none is a
// silent push, and iOS takes the subscription away after a few. A reply
// already on the screen the person is looking at needs no notice, so that
// one is shown silently and closed at once: only the device knows whether a
// window is in front and on the thread. An agent that needs the person always
// gets one, since its card may be out of view.
function inView(notice, windows) {
  return notice.kind === "reply" && windows.some(client => client.focused && new URL(client.url).pathname === notice.url)
}

function read(data) {
  try {
    const notice = data?.json()
    if (notice?.title) return notice
  } catch {}
  return { title: "New activity", url: "/" }
}

self.addEventListener("push", event => {
  event.waitUntil((async () => {
    const notice = read(event.data)
    // The app's badge: how many agents need the person, where a notice says.
    if ("badge" in notice && "setAppBadge" in self.navigator) {
      await (notice.badge ? self.navigator.setAppBadge(notice.badge) : self.navigator.clearAppBadge()).catch(() => {})
    }
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true })
    const quiet = inView(notice, windows)
    await self.registration.showNotification(notice.title, {
      body: notice.body, tag: notice.tag, data: { url: notice.url }, icon: "/icons/app-192.png", silent: quiet
    })
    if (quiet) (await self.registration.getNotifications({ tag: notice.tag })).forEach(shown => shown.close())
  })())
})

// Opens the thread: the window already on it, else the app's open window
// moved there (an installed app has one), else a new one.
self.addEventListener("notificationclick", event => {
  event.notification.close()
  const url = new URL(event.notification.data?.url ?? "/", self.location.origin)
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true })
    const open = windows.find(client => new URL(client.url).pathname === url.pathname)
    if (open) return open.focus()
    const other = windows.find(client => "navigate" in client)
    if (other) return (await other.focus()).navigate(url.href)
    return self.clients.openWindow(url.href)
  })())
})
