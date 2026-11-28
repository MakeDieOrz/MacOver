# Keymap Authoring (.playmap) with MacOver MCP

## Workflow

1. Inspect existing mappings via `macover_keymap(bundleID: ..., op: "list")` and `op: "get"`.
2. For canvas/game layouts (`canvas=1`), run `macover_screenshot(bundleID: ..., maxDim: 1024)` once to locate HUD buttons and virtual joysticks.
3. Convert screen positions into MacOver's normalized `0.0...100.0` (`xCoord`, `yCoord`) coordinate space with appropriate `size` (`1...100`).
4. Validate before saving:
   - `macover_keymap(bundleID: ..., op: "validate", keymap: ...)`
   - Fix any out-of-range coordinates or malformed button/joystick entries.
5. Save atomically:
   - `macover_keymap(bundleID: ..., op: "put", name: "default", keymap: ...)`
