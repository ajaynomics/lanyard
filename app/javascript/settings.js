// Settings' own controllers, loaded with the page that uses them
// (settings/accounts/_notifications, agents/new) rather than with every page, so a
// thread's first load stays within its budget.
import { application } from "controllers/application"
import NotificationsController from "settings/notifications_controller"
import AddressPreviewController from "settings/address_preview_controller"

application.register("notifications", NotificationsController)
application.register("address-preview", AddressPreviewController)
