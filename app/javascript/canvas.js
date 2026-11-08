// The canvas's own controllers, loaded with the canvas (conversations/documents/_canvas)
// rather than with every page, so a thread's first load stays within its budget.
import { application } from "controllers/application"
import DoneController from "canvas/done_controller"

application.register("canvas-done", DoneController)
