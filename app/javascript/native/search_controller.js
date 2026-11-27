import { SearchBridgeController } from "@joemasilotti/bridge-components"

// The phone app's own search bar (Bridge Components' search, under the app's own name) types into the page's search
// field, and its input event searches as typing there does (filters_controller.js), so the address and the results
// follow it. The name is "native-search", not the library's "search": builds already out answer "search" unchecked,
// so only a build that registers NativeSearchComponent hides the field (native.css). Loaded only in the app.
export default class extends SearchBridgeController {
  static component = "native-search"

  type({ detail: { query } }) {
    const field = this.element.elements.q
    field.value = query ?? ""
    field.dispatchEvent(new Event("input"))
  }
}
