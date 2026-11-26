import Foundation

/// Words that depend on whether a partner service is configured.
/// Solo wording is used only when the app knows it is solo; the partner wording is the default.
enum PartnerWording {
    static let partnerUninstallSentence = "I understand my partner will be notified"
    static let soloUninstallSentence = "I understand I am removing Clearpath"
    static let partnerRestoreNote = "Administrator approval is required. Clearpath records a restore event for partner alerts."
    static let soloRestoreNote = "Administrator approval is required."

    /// `nil` means the app can't tell, which keeps the partner wording.
    static func uninstallSentence(solo: Bool?) -> String {
        solo == true ? soloUninstallSentence : partnerUninstallSentence
    }

    static func restoreNote(solo: Bool?) -> String {
        solo == true ? soloRestoreNote : partnerRestoreNote
    }

    /// Solo means no partner service is configured for this app, the same test Setup uses.
    static var currentSolo: Bool {
        ProcessInfo.processInfo.environment["CLEARPATH_PARTNER_STATE"] == nil
    }
}
