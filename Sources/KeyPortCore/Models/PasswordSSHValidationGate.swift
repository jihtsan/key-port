public struct PasswordSSHValidationGate: Sendable {
    public private(set) var revision = 0
    public private(set) var check: AuthenticationCheck?
    private var validatedRevision: Int?

    public init() {}

    public var canSave: Bool {
        validatedRevision == revision && check?.state == .succeeded
    }

    public mutating func inputChanged() {
        revision &+= 1
        check = nil
        validatedRevision = nil
    }

    @discardableResult
    public mutating func beginTest() -> Int {
        validatedRevision = nil
        check = AuthenticationCheck(
            state: .checking,
            detail: "Testing password-only SSH authentication..."
        )
        return revision
    }

    public mutating func finishTest(_ result: AuthenticationCheck, for testedRevision: Int) {
        guard testedRevision == revision else { return }
        check = result
        validatedRevision = result.state == .succeeded ? revision : nil
    }
}
