// The screen page's controller, loaded with that page alone (conversations/screens/show)
// rather than with every page, so a thread's first load stays within its budget.
import { application } from "controllers/application"
import ScreenController from "screen/screen_controller"

application.register("screen", ScreenController)
