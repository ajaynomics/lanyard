// Configure your import map in config/importmap.rb. Read more: https://github.com/rails/importmap-rails
import "@hotwired/turbo-rails"
import "controllers"

// The PWA's service worker (app/views/pwa/service-worker.js): installable, and
// an offline page instead of the browser's error.
if ("serviceWorker" in navigator) navigator.serviceWorker.register("/service-worker", { scope: "/" })
