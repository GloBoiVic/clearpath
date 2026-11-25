struct UninstallConfirmation {
    static let sentence = "I understand my partner will be notified"
    private(set) var text = ""
    private var deadline: ContinuousClock.Instant?

    mutating func update(_ text: String, at now: ContinuousClock.Instant) {
        guard !self.text.utf8.elementsEqual(text.utf8) else { return }
        self.text = text
        deadline = text.utf8.elementsEqual(Self.sentence.utf8) ? now + .seconds(60) : nil
    }

    func allowsAuthorization(at now: ContinuousClock.Instant) -> Bool {
        guard let deadline else { return false }
        return now >= deadline
    }

    func secondsRemaining(at now: ContinuousClock.Instant) -> Int? {
        guard let deadline else { return nil }
        guard now < deadline else { return 0 }
        let remaining = (deadline - now).components
        return Int(remaining.seconds) + (remaining.attoseconds > 0 ? 1 : 0)
    }
}
