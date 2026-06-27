import Foundation

public struct StopWrappedSessionRequest: Codable, Equatable, Sendable {
    public var confirmStop: Bool

    public init(confirmStop: Bool = false) {
        self.confirmStop = confirmStop
    }
}

public struct StopWrappedSessionResponse: Codable, Equatable, Sendable {
    public var foregroundState: ControlForegroundResponse

    public init(foregroundState: ControlForegroundResponse) {
        self.foregroundState = foregroundState
    }
}
