# Design QA — Issue #51 Node Workspace

## Comparison target

- Source visual truth: `/tmp/keyport-design-qa.XTfAql/reference.png`
- Rendered implementation: `/tmp/keyport-design-qa.XTfAql/implementation-final.jpeg`
- Full-view comparison: `/tmp/keyport-design-qa.XTfAql/full-comparison-final.png`
- Focused workspace comparison: `/tmp/keyport-design-qa.XTfAql/workspace-comparison-final.png`
- Source pixels: 1487 × 1058
- Implementation pixels: 1224 × 768
- Native viewport: expanded KeyPort macOS window on the available 1224 × 768 desktop capture surface
- Density normalization: the source was proportionally scaled to 768 px high (1079 × 768) for the full comparison; the implementation remained 1224 × 768. No source content was cropped in the full-view comparison. The focused comparison used the central workspace plus account inspector from both images and normalized both regions to 700 px high.
- State: Light appearance, Nodes destination selected, `gl-mt3600` selected, `root` account selected, LAN route selected, account inspector visible.

The source is taller and contains illustrative demo data (two accounts, four routes, tags, and more nodes). The implementation uses the user's real local data (one account and one route for the selected node). Data-volume differences were treated as expected, while hierarchy, pane structure, density, controls, and selection treatment were compared directly.

## Full-view comparison evidence

The final comparison shows the same four-region hierarchy as the source: application source list, searchable node list, node/account/route workspace, and selection-driven account inspector. Pane proportions remain responsive to the shorter available desktop viewport. Native sidebar and toolbar materials replace custom opaque chrome, and the central selected account uses the same light accent emphasis as the source.

## Focused comparison evidence

The focused comparison confirms that the high-priority information remains above the fold in the same order: node identity, account/route/status selectors, Test Connection and Open in Terminal, SSH accounts, then network routes. Account rows and route rows use the source's continuous-list/table treatment, system icons, semantic status colors, compact borders, and aligned columns. The inspector retains the same account header, quick actions, details, edit, and destructive action hierarchy.

## Required fidelity surfaces

- Fonts and typography: System San Francisco typography is used throughout. Final title, section, body, caption, monospaced address, and status weights reproduce the source hierarchy without truncation at the expanded viewport; compact-width rows fall back to a reduced metadata layout.
- Spacing and layout rhythm: Four stable panes, section dividers, 24 pt workspace insets, continuous account surfaces, table headers, and responsive compact rows match the source's grouping. No overlap or persistent-control overflow was observed at either the restored compact window or expanded window.
- Colors and visual tokens: Semantic system materials and foreground styles provide the requested Apple-like glass response in Light/Dark appearance. Accent selection, green availability, orange requirements, red destructive actions, and secondary metadata match the source's intent.
- Image quality and asset fidelity: The source contains no product photography or custom illustrations. The implementation uses native SF Symbols for every UI icon; no emoji, placeholder raster art, custom SVG, or code-drawn substitute is present.
- Copy and content: Node, account, path, action, and inspector labels are concise Chinese UI copy. Dynamic names, addresses, aliases, counts, and statuses come from the local model rather than hard-coded mock content.
- States and interactions: Node selection updates the central workspace and inspector; selecting a node without an account presents a disabled connection state and empty inspector; node search filters and restores the list; account and route selectors remain real controls. Test Connection, Open in Terminal, copy command, and Share use the selected account/route. Live SSH connection and terminal launch were not invoked during visual QA to avoid changing external connection/audit state.
- Accessibility: Native buttons, menus, lists, labels, selection, keyboard focus, and accessibility names are exposed in the macOS accessibility tree. Status is communicated by text and icon as well as color.

## Comparison history

### Iteration 1

- Earlier finding (P2, responsiveness): At the restored compact window width, full account metadata and fixed route-table columns compressed the account name and route type until they were effectively unreadable.
- Fix: Added `ViewThatFits` responsive account metadata and a compact route-row layout while preserving the full table at reference-like widths.
- Post-fix evidence: The compact Computer Use pass exposed `root`, alias, status, LAN address/source, and availability without clipping; selecting a zero-account node also produced a usable empty state.

### Iteration 2

- Earlier finding (P2, typography and density): `/tmp/keyport-design-qa.XTfAql/workspace-comparison.png` showed the node title and continuous account/route rows materially smaller than the reference.
- Fix: Increased the node title to the macOS title scale, promoted section headings, enlarged account avatars, increased row padding, and reduced the selected-route fill to a subtle system tint.
- Post-fix evidence: `/tmp/keyport-design-qa.XTfAql/workspace-comparison-final.png` shows comparable title hierarchy and row rhythm, with no clipping or overlap.

## Findings

No actionable P0, P1, or P2 differences remain.

## Follow-up polish

- P3: The source includes more populated tags, accounts, and route rows than the current local dataset. The implemented components render these states when that data exists; a later fixture-based screenshot could demonstrate the fully populated variant without altering user data.
- P3: The source viewport is taller than the available desktop capture, so lower inspector content has more breathing room in the mock. The implementation scrolls natively when vertical space is constrained.

## Implementation checklist

- [x] Four-pane native macOS structure
- [x] Search and stable node selection
- [x] Account selector and continuous account list
- [x] Route selector and responsive network table
- [x] Test, terminal, copy, and share actions use the selected account and route
- [x] Account inspector follows selection
- [x] Compact and expanded viewport checks
- [x] Side-by-side full and focused comparisons

final result: passed
