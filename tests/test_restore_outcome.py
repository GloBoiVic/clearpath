"""The panel's Restore internet result, read from real osascript error text (#74)."""

import unittest

from test_uninstall_confirmation import run_swift


class RestoreOutcomeTests(unittest.TestCase):
    def test_a_refusal_says_why_and_what_to_do_next_and_a_cancel_says_nothing(self):
        driver = r'''
let next = "Try again. If it still fails, use Leave Clearpath to remove Clearpath and restore DNS."
let refused = RestoreOutcome.from(status: 1, errorOutput: "0:87: execution error: The original DNS settings could not be verified. (2)\n")
precondition(refused == .failed(reason: "The original DNS settings could not be verified."))
precondition(refused.message == "Restore internet didn’t finish. The original DNS settings could not be verified. " + next)
precondition(RestoreOutcome.from(status: 1, errorOutput: "6:22: execution error: User canceled. (-128)\n") == .canceled)
precondition(RestoreOutcome.canceled.message == nil)
precondition(RestoreOutcome.from(status: 0, errorOutput: "") == .completed)
precondition(RestoreOutcome.completed.message == nil)
for unknown in ["", "osascript: crashed", "0:1: execution error: Something else. (-1708)",
                "0:1: execution error: " + String(repeating: "x", count: 201) + " (2)"] {
    let outcome = RestoreOutcome.from(status: 1, errorOutput: unknown)
    precondition(outcome == .failed(reason: nil), unknown)
    precondition(outcome.message == "Restore internet didn’t finish. " + next)
}
'''
        run_swift(driver, "RestoreOutcome.swift")


if __name__ == "__main__":
    unittest.main()
