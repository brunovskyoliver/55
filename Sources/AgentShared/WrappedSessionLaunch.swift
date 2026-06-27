import Foundation

public struct StartWrappedSessionRequest: Codable, Equatable, Sendable {
    public init() {}
}

public struct StartWrappedSessionResponse: Codable, Equatable, Sendable {
    public var attachedSession: AttachedSession
    public var foregroundState: ControlForegroundResponse

    public init(attachedSession: AttachedSession, foregroundState: ControlForegroundResponse) {
        self.attachedSession = attachedSession
        self.foregroundState = foregroundState
    }
}
