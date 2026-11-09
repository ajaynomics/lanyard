// Settings' own controllers, loaded with the pages that use them (layouts/settings,
// agents/new) rather than with every page, so a thread's first load stays within
// its budget.
import { application } from "controllers/application"
import NotificationsController from "settings/notifications_controller"
import AddressPreviewController from "settings/address_preview_controller"
import AutosaveController from "settings/autosave_controller"
import ThinkingLevelsController from "settings/thinking_levels_controller"
import SearchListController from "settings/search_list_controller"

application.register("notifications", NotificationsController)
application.register("address-preview", AddressPreviewController)
application.register("autosave", AutosaveController)
application.register("thinking-levels", ThinkingLevelsController)
application.register("search-list", SearchListController)
