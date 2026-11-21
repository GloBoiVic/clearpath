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

## Menu-bar panel

The menu-bar mark is a monochrome path inside a shield. Its silhouette or badge distinguishes protection and partner states. Give it an accessibility label naming both. The panel opens with **Clearpath**, then **Protection is on** with a green check when protection is verified. Below it, show **Partner** and **Pending requests** as separate rows. Place **Block a site** directly below the divider, followed by **Blocked sites** and **Partner settings**.

Use words and symbols together for status. An unknown filter state gets an explicit status message. If restarting fails, give **Restore internet** priority and explain that using it alerts the partner. Keep browsing history, blocked-attempt counts and pause controls out of every view.

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

## Main screen

Menu-bar panel. SwiftUI screen in `app/Clearpath.swift`. Approved by Victor on 2026-11-21. Victor approved the visual direction of the light and dark mockup on 2026-11-21.

## Decisions

| Decision | Made by | Why |
|---|---|---|
| Clearpath identity, native controls and path-in-a-shield mark | Victor accepted the recommendation | Recognizable in the menu bar and familiar to operate |
| Control Center and System Settings references, comfortable density | Victor accepted the recommendation | Protection, partner status and the primary action are visible at a glance |
| System appearance and accent | Victor accepted the recommendation | Respects the Mac’s preferences |
| Initial dimensions and reference colors | Agent | Gives the first SwiftUI panel measurable starting values |

Approved by Victor on 2026-11-21.
