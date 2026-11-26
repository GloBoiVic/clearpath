"""Exercise the app's confirmation gate with an injected monotonic time."""

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


def run_swift(driver, *sources):
    with tempfile.TemporaryDirectory(prefix="clearpath-uninstall-confirmation-") as directory:
        work = Path(directory)
        (work / "main.swift").write_text(driver)
        executable = work / "confirmation"
        subprocess.run(
            ["swiftc", "-module-cache-path", str(work / "cache"),
             *[str(ROOT / "app" / name) for name in sources], str(work / "main.swift"),
             "-o", str(executable)],
            check=True, capture_output=True, timeout=300,
        )
        subprocess.run([str(executable)], check=True, capture_output=True, timeout=30)


class UninstallConfirmationTests(unittest.TestCase):
    def test_solo_wording_never_mentions_a_partner_and_unknown_keeps_partner_wording(self):
        driver = '''
let partnerSentence = "I understand my partner will be notified"
let partnerNote = "Administrator approval is required. Clearpath records a restore event for partner alerts."
precondition(PartnerWording.uninstallSentence(solo: false) == partnerSentence)
precondition(PartnerWording.uninstallSentence(solo: nil) == partnerSentence)
precondition(PartnerWording.restoreNote(solo: false) == partnerNote)
precondition(PartnerWording.restoreNote(solo: nil) == partnerNote)
let soloSentence = PartnerWording.uninstallSentence(solo: true)
let soloNote = PartnerWording.restoreNote(solo: true)
precondition(soloSentence == "I understand I am removing Clearpath")
precondition(soloNote == "Administrator approval is required.")
precondition(!soloSentence.lowercased().contains("partner"))
precondition(!soloNote.lowercased().contains("partner"))
precondition(UninstallConfirmation.sentence == partnerSentence)
let start = ContinuousClock().now
var confirmation = UninstallConfirmation(sentence: soloSentence)
confirmation.update(partnerSentence, at: start)
precondition(!confirmation.allowsAuthorization(at: start + .seconds(120)))
confirmation.update(soloSentence, at: start)
precondition(confirmation.secondsRemaining(at: start) == 60)
precondition(confirmation.allowsAuthorization(at: start + .seconds(60)))
'''
        run_swift(driver, "UninstallConfirmation.swift", "PartnerWording.swift")

    def test_only_an_exact_sentence_held_for_sixty_seconds_allows_authorization(self):
        driver = '''
let start = ContinuousClock().now
let sentence = "I understand my partner will be notified"
var confirmation = UninstallConfirmation()
confirmation.update(sentence + " ", at: start)
precondition(!confirmation.allowsAuthorization(at: start + .seconds(120)))
confirmation.update(sentence, at: start)
precondition(confirmation.secondsRemaining(at: start) == 60)
precondition(!confirmation.allowsAuthorization(at: start + .milliseconds(59999)))
precondition(confirmation.secondsRemaining(at: start + .milliseconds(59999)) == 1)
precondition(confirmation.allowsAuthorization(at: start + .seconds(60)))
confirmation.update(sentence.lowercased(), at: start + .seconds(61))
precondition(!confirmation.allowsAuthorization(at: start + .seconds(120)))
confirmation.update(sentence, at: start + .seconds(62))
precondition(!confirmation.allowsAuthorization(at: start + .seconds(121)))
precondition(confirmation.allowsAuthorization(at: start + .seconds(122)))
'''
        run_swift(driver, "UninstallConfirmation.swift", "PartnerWording.swift")
