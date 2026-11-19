/// A notification delegate's completion handler from iOS, carried to the
/// main actor and called there, once (PushRegistration+Notices.swift on the
/// phone, NoticeDesk on the Watch). iOS does not mark it Sendable; it is only
/// ever called on the main thread, after the work it waits for.
struct NoticeCompletion: @unchecked Sendable {
    let call: () -> Void
}
