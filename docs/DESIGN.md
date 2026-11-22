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

Place **Set up protection** after **Partner settings**. Use words and symbols together for status. An unknown filter state gets an explicit status message. If restarting fails, give **Restore internet** priority and explain that using it alerts the partner. Keep browsing history, blocked-attempt counts and pause controls out of every view.

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

### Setup

Use native grouped sections for **DNS filter**, **Safari**, and **Chrome and Firefox**. **Check DNS status** reports the result of the most recent check. Explain the Private Relay setting, reveal the browser profile in Finder, and specify how to check its effective settings in each browser.

### Partner settings

Use native grouped sections for **Primary partner** and **Backup partner**, with a labeled email input and an invitation status. Show **A backup partner is strongly recommended.** in the backup section. The backup is optional. Use **Send invitation** for an empty slot and **Replace invitation** for an unaccepted invite. Accepted slots show their status and address. Use **Refresh** to check for acceptance.

The email and acceptance page identify the invited role. The partner selects **Accept invitation** without an account. The result is **Invitation accepted** or **This invitation is no longer available.** The approved copy is maintained in `clearpath/partner-copy.json`.

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
| Panel opens below the menu bar, extending right from the shield, and flips left near the screen edge | Victor chose on 2026-11-22 | Opens beside the shield rather than straight down, without covering the menu bar |

Approved by Victor on 2026-11-21.
