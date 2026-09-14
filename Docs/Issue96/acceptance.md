# Issue 96 — Current repair acceptance

Current source: `6269ed40cf31f882c37b3a27217bbd6b1e51729e`. PR #97 remains stacked on #95 and draft pending visual sign-off. Old evidence under `9cfc4fd` is historical, not current-source proof.

## Changes after review

- Restore contextual primary actions: missing/unknown account authorization → 配置免密; unreachable address → 检查地址; installed authorization → 在终端打开. Configuration uses the selected server alias/description/account/address/port and no stored password.
- Use an identified form session so SwiftUI cannot present stale example input on first open. Keep new-server draft retention separate from configuring an existing server. Existing alias owner is preserved, with duplicate validation still applied to newly added servers.
- List and group inspector use full verification counts. Selecting a multi-path server does not silently select the first path or claim its account status for the entire server. Explicitly selected paths retain their own authorization and reachability.
- Fit uses actual available dimensions, with 90 points above and below reserved for toolbar/legend. Removed the 75% minimum that caused overflow. Fit is an overview; users can zoom for detailed canvas labels while the inspector remains full size.
- Path labels now use the two-line account/address + verification hierarchy of the Figma states. Mixed-status node captions use neutral color.
- Verified simulated access updates only the in-memory fixture workspace on return; failure/cancellation does not report success. New paths can appear after a completed simulation. No production persistence or remote effects were introduced.

## Verification on current source

`swift test --filter KeyPortInterfaceTests`: **37 passed**. New tests cover account action policy, own-alias context versus new-server collision, and fit bounds in a 604-point canvas and a large graph. Existing first-access/alias/multi-path regressions pass. `script/build_design_preview.sh` built, signed, validated and launched the app; staged diff whitespace check passed.

Actual Computer Use screenshots and AX in `evidence/6269ed4`:

1. Context form has `home-router`, root, correct address/port and an empty password; configuration title identifies an existing server.
2. Submit with simulated existing-key authentication → host confirmation → login → authorization → verification → success → terminal handoff feedback → return to the SAME server with installed authorization and a new verified-path timestamp.
3. Unreachable path opens its address/account form; cancel leaves it unchanged.
4. Six-path list and server inspector show **1 verified / 4 pending / 1 failed**, with no implicit first-path selection.
5. Actual resized window screenshot is 1103×745. Fit at approximately 51% shows all six paths and all three server nodes without canvas scrollbars/toolbar overlap. Inspector remains separately readable. Geometry tests additionally cover the declared 1100-point minimum.
6. Long alias and Chinese description use truncation plus full AX/help text, without overlapping actions. Empty workspace shows add-server entry and no inferred paths.

The manifest records exact bundle path, signed binary hash and all screenshot/AX/log hashes. Computer Use rendering changes screenshot pixel scale by window size: default screenshots are 1237×768 for a 1320×820 logical window; resized screenshots are recorded at their actual tool-rendered size. No screenshot dimensions were fabricated.

## Figma and remaining acceptance boundary

File: https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY
Baseline `6:2`, naming `27:2`/`28:2`; research `37:2`; new state drafts `41:2` (two paths), `44:2` (collapsed), `45:2` (expanded). Original three-column split is retained. No design frame was silently rewritten to match an implementation defect.

Functional review findings are fixed and runtime-verified. The native app still uses system Chinese fonts versus Figma's Noto Sans SC substitute; dynamic fit/scrolling, interactive hit areas, and selectable inspector rows have no fully equivalent static-frame representation. Thus these checks are **not pixel-level visual approval**. User visual sign-off, complete assistive-technology traversal, and existing #90/#92 visual exceptions remain outstanding. Do not merge the preview stack, close the entire #82, or claim real SSH/CloudKit acceptance.

## Production seams

AccessWorkspaceSnapshot remains the injection boundary; DirectAccessProjection only accepts valid configured paths belonging to the current device. Authorization keys use device/server/account, independent of address. Future multi-hop paths need explicit ordered hop identities; current jump-host UI is planning only. KeyPort production entry, SSH configuration, Keychain, CloudKit and real terminal/clipboard behavior are untouched.
