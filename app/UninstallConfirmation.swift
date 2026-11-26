struct UninstallConfirmation {
    /// The partner sentence, which stays the default when the mode is unknown.
    static let sentence = PartnerWording.partnerUninstallSentence
    let sentence: String
    private(set) var text = ""
    private var deadline: ContinuousClock.Instant?

    init(sentence: String = UninstallConfirmation.sentence) {
        self.sentence = sentence
    }

    mutating func update(_ text: String, at now: ContinuousClock.Instant) {
        guard !self.text.utf8.elementsEqual(text.utf8) else { return }
        self.text = text
        deadline = text.utf8.elementsEqual(sentence.utf8) ? now + .seconds(60) : nil
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
