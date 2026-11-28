---
name: cover-use
description: Control and troubleshoot iOS apps running inside MacOver via MCP. Use when inspecting MacOver app state, automating Catalyst iOS UI with low token cost, debugging compatibility or MITM traffic, or authoring .playmap keymaps.
---

# cover-use Operational Guide

Follow a **three-tier perception and control hierarchy** to minimize token usage and anti-cheat exposure:

## 1. Three-Tier Routing Strategy

1. **Tier 0 — Host `AXUIElement` (`source: "auto"` / `"ax"`, Zero Injection — Always First)**:
   - Call `macover_apps(op: "list")` first to check `axReady`, running `pid`, and `bridgeReady`.
   - Prefer `macover_ui_snapshot(bundleID: ...)` with default pruning (`interactiveOnly: true`, `viewportOnly: true`, `bounds: "none"`, `maxNodes: 80`).
   - Execute semantic actions (`press`, `set_value`, `input`, `scroll_to`, `menu`, `increment`, `decrement`) via `macover_act` using revisioned `[r<rev>e<N>]` refs and default `observe: "diff"`.
2. **Tier 1 — Opt-In `CoverUseBridge.dylib` (`bridge: true`)**:
   - Only launch/restart with `bridge: true` when:
     - Accessibility permission is not granted (`axReady: false`),
     - You need physical touch gestures (`tap`, `long_press`, `swipe`, `drag`, `pinch`), or
     - You need an occluded/background UIKit window capture.
3. **Tier 2 — Visual Fallback (`macover_screenshot`)**:
   - Only capture screenshots when `canvas=1` (`MTKView` / Metal game surface with zero AX nodes), icons lack labels, or visual verification is required.
   - Prefer `clipRef` or `clipNorm` with default `maxDim: 768` and `format: "jpeg"` to save context tokens.

## 2. Token-Minimal Interaction Loop

- Batch deterministic sequences (clear + type + submit) into a single `macover_act(steps: [...], settleMs: 250, observe: "diff")` call.
- Wait for UI or API milestones inside the MacOver host with `macover_wait` (`textAppears`, `textDisappears`, `refExists`, `networkMatch`, `appReady`) instead of polling with repeated snapshots.
- Narrow large trees with `scopeRef`, `query`, `roles`, or request `bounds: "center"` only when coordinate math is needed.
- On `STALE_REF`, match against the returned candidate lines instead of re-fetching full unfiltered trees.

## 3. Dual UI + MITM Troubleshooting

- Pair UI actions with `macover_network(op: "list")` and targeted `macover_network(op: "detail", id: ..., jsonPath: ...)` / `grep: ...`.
- Sensitive headers (`Authorization`, `Cookie`, API keys), URL query secrets, and sensitive request/response bodies stay redacted unless explicitly unlocked in Settings -> MCP.
- Use `macover_network_rules` to test live URL block/mock rules and `macover_diagnostics(sections: [...])` selectively (`runtime`, `macho`, `safemode`, `logs`, `crash`).
- See [compatibility-debugging.md](references/compatibility-debugging.md) and [keymap-authoring.md](references/keymap-authoring.md).

## 4. Human-in-the-Loop Safety Boundaries

- **Pause and ask the user to take over manually** for payments/IAP purchases, password/credential entry, 2FA/OTP codes, CAPTCHAs, or destructive account actions.
- Never attempt to extract KeyCover / PlayChain secrets or escalate privileges.
