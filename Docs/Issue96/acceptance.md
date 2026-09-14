# Issue 96 — Graph preview and multiple paths

Source commit: `9cfc4fdaf8c093b7aa38f810516cd9c65951014b`.
Branch: `codex/issue-96-graph-preview`, stacked on PR #95.

## Scope and design

User authorized the multiple-path proposal on 2026-09-14. Existing #96 scope applies. New UI remains a fixture-only preview; production entry and main are not replaced.

Figma file: https://www.figma.com/design/RGpDDMdxvoPwzhlTB5RyiY
- Original direct layout: `6:2`; future jump-host planning: `6:232`.
- Naming rules: `27:2`, `28:2`.
- Research and proposal: `37:2`.
- New state drafts: `41:2` two paths, `44:2` six collapsed, `45:2` six expanded.

Existing Figma contains no component instances, Code Connect definitions, local variables or text styles for this screen. New state drafts reuse the existing Graph frame and its fonts and parts. They are state drafts pending visual acceptance, not approved replacements for all original frames.

## Delivered behavior

List and Graph use one injected AccessWorkspace. Stable server/path IDs retain selection and search. Configured paths alone produce directed edges; isolated servers remain without edges. Account authorization is independent of address reachability.

Paths group by current device and server. One to three paths have separate curves, endpoints and labels; four or more are collapsed by default with counts for verified/pending/failed. Expanding exposes each path; collapsing preserves the selected path in the inspector. Expanded state survives list/Graph switching; selecting a path opens its group. Paths use ID order rather than unrelated whole-graph indexes. Expanded graphs can scroll to preserve legibility; fit does not shrink below 75%.

No SSH configuration, Keychain, CloudKit, terminal, clipboard or remote write occurs. Status and time are fixture examples. Jump-host sheet is planning text only.

## Verified on this source

- `swift test --filter KeyPortInterfaceTests`: 35 tests passed, including prior form/alias/first-access tests. This is the interface suite, not the full production suite.
- `./script/build_design_preview.sh`: build, ad-hoc signing and bundle validation succeeded; exact App path is in the evidence manifest.
- `git diff --cached --check`: passed before source commit.
- Actual App: two paths, filtered two paths, six-path collapse/expand, exact failed-path detail, list/Graph search/selection/expansion retention, collapse retaining inspector selection, Cmd+] navigation to device, no-search-results.
- Earlier actual-window checks in this task covered fit-to-canvas and IPv6 detail; final captures cover the changed paths above.

`evidence/9cfc4fd` contains unmodified Computer Use screenshots, matching AX dumps, build/test logs, and SHA-256 manifest. Screenshots are tool-rendered 1237×768 window images for a 1320×820 logical window, not fabricated pixel-perfect Figma-size exports. The signed App binary hash differs from the unsigned SwiftPM executable by signing; the manifest hashes the actual launched bundle.

## Figma comparison and outstanding acceptance

| Area | Evidence / status |
| --- | --- |
| Sidebar 200, canvas 824, inspector 296 at default size | Implemented; new drafts preserve original three-column dimensions |
| Two paths without overlapping labels | Regression test and actual App capture pass |
| Six paths with mixed status and individual selection | Test and actual App capture pass |
| Font | Native system Chinese plus bundled JetBrains Mono; Figma uses Noto Sans SC substitute; user visual acceptance pending |
| Path labels and inspector | Native App uses filled clickable labels and separate selectable rows; Figma state drafts use text labels/path directory; visual parity not yet accepted |
| Dynamic layout | Expansion allocates vertical room and shifts node positions; Figma is a static state composition; transition/position behavior needs visual acceptance |
| Narrow window, long text, empty data and full AX traversal | Fixtures exist; final-source comprehensive UI acceptance still pending |
| Whole first-access GUI replay | Unit regressions pass; not replayed end-to-end on this source |

Therefore #96 is **implemented for the reviewed multiple-path scope, pending broader visual/UI acceptance**. Do not mark the whole Issue passed, merge the stacked previews, close #82, or begin production SSH takeover on the strength of these checks. Prior #90/#92 visual exceptions remain outstanding.

## Production migration seams

AccessWorkspaceSnapshot is the injection boundary for future service data. DirectAccessProjection filters invalid/orphan/foreign-device paths and does not infer discovery edges. AccessAuthorizationKey keeps device/server/account semantics. A future adapter must connect persisted server naming, configured paths and verified identities without reintroducing the old NodeWorkspace layout. Future multihop needs explicit ordered hop identities; never group different hop sequences as identical direct paths.
