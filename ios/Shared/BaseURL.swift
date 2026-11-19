import Foundation

/// The install's address, from the build (LANYARD_BASE_URL in project.yml),
/// in both apps' Info.plist: the phone opens it, the Watch calls it. A Debug
/// build's UI test may point it elsewhere with `-LanyardBaseURL <url>`, to
/// show the server out of reach (BUILD.md); never a release build.
let baseURL: URL = {
    #if DEBUG
    if let override = UserDefaults.standard.string(forKey: "LanyardBaseURL"), let url = URL(string: override) { return url }
    #endif
    let configured = Bundle.main.object(forInfoDictionaryKey: "LanyardBaseURL") as? String
    return URL(string: configured ?? "") ?? URL(string: "http://localhost:3000")!
}()
