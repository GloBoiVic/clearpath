---
name: Clearpath
description: A quiet, familiar macOS utility with comfortable spacing.
colors:
  ground: "#F5F5F7"
  ground-dark: "#242426"
  ink: "#19191B"
  ink-dark: "#F5F5F7"
  text: "#303033"
  text-dark: "#E5E5E7"
  muted: "#5B5B60"
  muted-dark: "#B8B8BE"
  rule: "#D3D3D8"
  rule-dark: "#49494E"
  accent: "#005CC5"
  accent-dark: "#77B7FF"
  healthy: "#20733D"
  healthy-dark: "#75DC93"
  attention: "#914600"
  attention-dark: "#FFB765"
typography:
  display: {fontFamily: "macOS system", fontSize: 17, fontWeight: 600}
  body: {fontFamily: "macOS system", fontSize: 13, lineHeight: 1.4}
  label: {fontFamily: "macOS system", fontSize: 13}
  data: {fontFamily: "macOS system", fontSize: 13}
spacing: {xs: 4pt, sm: 8pt, md: 12pt, lg: 16pt, xl: 24pt}
rounded: {sm: 6pt, md: 10pt}
components:
  primary-action: "Native prominent button, system accent"
  status-row: "Leading symbol and label, trailing value"
  navigation-row: "Leading symbol, destination title and disclosure chevron"
---

# Clearpath design system

## Appearance and layout

Clearpath feels quiet, familiar and reassuring. The menu-bar panel takes its status rows from Control Center. Setup and settings use the labeled groups found in System Settings. Follow the Mac’s light or dark appearance and accent preference. The hex pairs above are solid reference colors. Use native semantic colors, popover material, button styling and system accessibility settings at runtime.

Use the system font throughout. Give the protection headline semibold weight and secondary values regular weight. Start the popover at 320 pt wide with 16 pt side insets. Use 8 pt between a symbol and its label and 12 pt between groups. Allow long status text to wrap. Use the system popover shadow and one separator between status and actions.

## App icon

The Finder icon uses a white shield with a winding blue path on a rounded blue tile. The app bundle uses `app/AppIcon.icns`.

## Menu-bar panel

The menu-bar mark is a monochrome path inside a shield. Its silhouette or badge distinguishes protection and partner states. Give it an accessibility label naming both. The panel opens with **Clearpath**, then **Protection is on** with a green check when protection is verified. Below it, show **Partner** and **Pending requests** as separate rows. Place **Block a site** directly below the divider, followed by **Blocked sites** and **Partner settings**.

The panel opens just below the menu bar with its left edge at the shield, so it extends to the right. When there is no room on the right, it flips so its right edge meets the shield's right edge, and it always stays on the icon's screen. It has no arrow and uses the popover material. Clicking outside it or pressing Escape closes it.

Place **Set up protection** after **Partner settings**, then **Leave Clearpath** when running from Applications. Use words and symbols together for status. An unknown filter state gets an explicit status message. If restarting fails, give **Restore internet** priority and explain that using it alerts the partner. Keep browsing history, blocked-attempt counts and pause controls out of every view.

While the filter has time to restart, show **Restarting protection…**. The recovery action requests administrator approval. Show **Restoring internet…** while it runs, **DNS restoration interrupted** if it must be retried, and **Previous DNS settings restored** with **DNS filtering is off** after confirmation. Until partner delivery is connected, describe the local event recorded for partner alerts.

## Screens

| Job | Surface |
|---|---|
| Set up protection and invite partners | Setup window |
| Check protection, add a site, see pending requests | Menu-bar panel |
| Manage blocks and request removals | Blocked-sites window |
| Manage partner invitations and changes | Partner settings |
| Leave Clearpath | Uninstall window |

~~~mermaid
flowchart LR
    Setup --> Panel[Menu-bar panel]
    Panel --> Add[Block a site]
    Panel --> Sites[Blocked sites]
    Panel --> Partners[Partner settings]
    Panel --> Uninstall
~~~

Setup, Block a site, Blocked sites, Partner settings and Leave Clearpath open as their own windows. Cmd-W closes them. Escape does nothing there and makes no sound, as in other Mac settings windows.

### Site blocks

**Block a site** opens a grouped form with a domain field and one-click shortcuts. Reddit, X and Tumblr appear under **Mixed sites**. Brave Search and Startpage appear under **Other search engines**. Each shortcut shows the domain it covers. Show the result of the addition beside the field and mark saved shortcuts as **Added**.

**Blocked sites** lists removal requests, the user's custom blocks, active adult list rules and any exceptions to the adult list. Each active rule can be selected for **Request removal**. Show **Requested** on a rule with a pending request. Show the selected rule, site and outcome in the request list. The panel's **Pending requests** count reflects requests that still need a decision or a policy update. Refresh the rules when the window opens and after a successful change.

The email includes the requested site and the decision deadline. Opening its link displays a confirmation page with the site and **Approve** and **Deny** buttons. Both explain that the selected rule covers the domain and its subdomains. Selecting a button shows the result. A used, invalid or expired link shows **This request is no longer available.**

### Setup

Use native grouped sections for **DNS filter**, **Safari**, **Browser profile**, and **Partners**. Start with **Install Clearpath** and explain the macOS administrator prompt. Show install progress, whether cancellation left the Mac unchanged, and the outcome of an attempted rollback. **Check DNS status** reports the last check. Show **Open at login** separately from DNS status. After DNS protection is on, explain the Private Relay setting, reveal the browser profile in Finder, and specify how to check its effective settings in each browser.

**Partners** repeats the Partner settings rows for each role, then **A backup partner is strongly recommended.** and the solo warning: **Without a partner, nobody is told when you remove a block or undo Clearpath. You can undo Clearpath without anyone knowing.** With no invited or accepted partner, **Finish setup** stays disabled until the user checks **I understand I can undo Clearpath without anyone knowing**. Finishing is recorded once. Afterwards the section shows **Setup complete. Removing a block or changing an accepted partner now needs partner approval or a 7-day wait.**

For the solo trial without a configured partner service, show the same warning and acknowledgement. **Finish setup** records completion locally and then shows **Setup complete without a partner**.

### Partner settings

Use native grouped sections for **Primary partner** and **Backup partner**, with a labeled email input and an invitation status. Show **A backup partner is strongly recommended.** in the backup section. The backup is optional. Use **Send invitation** for an empty slot and **Replace invitation** for an unaccepted invite. Accepted slots show their status and address, a **New partner email** input, **Request change**, and **Changing an accepted partner needs approval from the other partner or the one being replaced, or 7 days with no answer. The replaced partner is told.** An invitation created by an approved change is treated the same way: it shows its address with **Replace invitation** (or **Send invitation** once expired) to resend it to that address, plus the change controls, and no free email input. A pending request shows **Change requested** with the new address and hides the input; a denied one shows **Change denied** until the next request. Use **Refresh** to check for acceptance and decisions.

A partner change email names the role and both addresses. Its link opens **Review partner change** with **Approve** and **Deny**, under the same rules as a site removal page.

The email and acceptance page identify the invited role. The partner selects **Accept invitation** without an account. The result is **Invitation accepted** or **This invitation is no longer available.** The approved copy is maintained in `clearpath/partner-copy.json`.

### Uninstall window

**Leave Clearpath** explains what uninstall removes and shows the exact confirmation sentence above the text input. Show the 60-second countdown when the sentence matches and reset it when the text changes. Enable **Uninstall now** when the countdown finishes, then use the macOS administrator prompt. Show progress, cancellation and any retry instructions in the window. If macOS requires manual profile removal, show the exact profile name and identifier, the Device Management path and **Check profile and continue**. Confirm completion before quitting.

## Main screen

Menu-bar panel. SwiftUI screen in `app/Clearpath.swift`. Approved by Victor on 2026-11-21. Victor approved the visual direction of the light and dark mockup on 2026-11-21.

## Decisions

| Decision | Made by | Why |
|---|---|---|
| Clearpath identity, native controls and path-in-a-shield mark | Victor accepted the recommendation | Recognizable in the menu bar and familiar to operate |
| Blue Finder icon with a winding path through a white shield | Victor approved on 2026-11-21 | Carries the approved menu-bar mark into the app icon |
| Control Center and System Settings references, comfortable density | Victor accepted the recommendation | Protection, partner status and the primary action are visible at a glance |
| System appearance and accent | Victor accepted the recommendation | Respects the Mac’s preferences |
| Initial dimensions and reference colors | Agent | Gives the first SwiftUI panel measurable starting values |
| Setup Partners section, solo warning and acknowledgement, partner change controls, and partner-change email copy, as written above and in `clearpath/partner-copy.json` | Victor approved as drafted on 2026-11-25 | Finishes setup with or without a partner and changes an accepted partner through approval |
| Panel opens below the menu bar, extending right from the shield, and flips left near the screen edge | Victor chose on 2026-11-22 | Opens beside the shield rather than straight down, without covering the menu bar |
| Settings windows close with Cmd-W, not Escape, and Escape is silent | Victor decided on 2026-11-22 | Follows the Mac convention and avoids losing a half-typed partner email |

Approved by Victor on 2026-11-21.
