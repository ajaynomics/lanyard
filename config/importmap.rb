# Pin npm packages by running ./bin/importmap

pin "application"
pin "@hotwired/turbo-rails", to: "turbo.min.js"
pin "@hotwired/stimulus", to: "stimulus.min.js"
pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"
pin_all_from "app/javascript/controllers", under: "controllers"
# Only the screen page imports it (screen_controller.js), so no other page preloads it.
pin "@novnc/novnc", to: "@novnc--novnc.js", preload: false # @1.7.0
# The canvas's controllers load with the canvas (canvas.js), not with every page.
pin "canvas", preload: false
pin_all_from "app/javascript/canvas", under: "canvas", preload: false
# Settings' own controllers load with the page that uses them (settings.js), not with every page.
pin "settings", preload: false
pin_all_from "app/javascript/settings", under: "settings", preload: false
# The screen page's controller, the same way (screen.js).
pin "screen", preload: false
pin_all_from "app/javascript/screen", under: "screen", preload: false
# The Share sheet's pictures, loaded only on a composer that holds some (share.js).
pin "share", preload: false
