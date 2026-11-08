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
