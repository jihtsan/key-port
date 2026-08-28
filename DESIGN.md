# Design

## Source of truth
- Status: Current implementation baseline; the proposed Graph replacement is defined in `Docs/Graph拓扑与跨设备授权架构.md` and `Docs/整体重构与迁移计划.md`
- Last refreshed: 2026-08-06
- Primary product surfaces: macOS server, key, device, and audit views
- Evidence reviewed: `CONTEXT.md`, `Docs/SSH-KeyPort-一期需求规格.md`, `Docs/macOS-技术框架与组件选型.md`, `Sources/KeyPort/Features/Servers`, `Sources/KeyPort/Stores/AppModel.swift`

## Brand
- Personality: quiet, trustworthy, operational, and native to macOS
- Trust signals: explicit host-key confirmation, per-account authorization state, and clear credential boundaries
- Avoid: marketing-style dashboards, decorative cards, hidden security state, and dense redundant hierarchy

## Product goals
- Goals: make SSH account setup safe, make aliases easy to use, and make repeated server operations fast to scan
- Non-goals: embedded terminal sessions, command execution, or infrastructure monitoring
- Success signals: a user can identify the target account, copy its alias, and authorize the correct account without opening unrelated detail

## Personas and jobs
- Primary personas: macOS users managing several SSH endpoints and occasional multiple accounts on one endpoint
- User jobs: add an endpoint, verify its host identity, authorize this Mac, and use a stable SSH alias externally
- Key contexts of use: repeated desktop administration, quick status checks, and recovery on a second Mac

## Information architecture
- Primary navigation: Servers, Keys, Devices, Audit Logs
- Core routes/screens: server list -> selected SSH account detail; key/device/log lists -> focused detail
- Content hierarchy: endpoint first when accounts are plural; one compact account row when an endpoint has one account; account identity before operational status

## Design principles
- One endpoint should read as one item in the common case; do not make a server header and a repeated child row for a single account.
- Account-scoped security state stays visible and actionable: username, SSH alias, and authorization status belong to the account.
- Use progressive disclosure for uncommon multi-account cases: show endpoint metadata once, then list each account below it.
- Tradeoff: the server list is optimized for scanning; full host keys, passwords, and authorization history remain in account detail.

## Visual language
- Color: system macOS colors; reserve semantic colors for status and warnings
- Typography: native SwiftUI text styles with monospaced endpoint and alias values
- Spacing/layout rhythm: compact list rows, stable leading icon column, and predictable vertical padding
- Shape/radius/elevation: native List, Section, GroupBox, and system controls; no decorative floating panels
- Motion: minimal native transitions; never make security state depend on animation
- Imagery/iconography: SF Symbols with text labels or help text for unfamiliar actions

## Components
- Existing components to reuse: `NavigationSplitView`, `List`, `Section`, `ContentUnavailableView`, `StatusLabel`, and `ServerDetailView`
- New/changed components: `ServerConnectionGroup`, `ServerGroupHeader`, and the compact `ServerAccountRow`
- Variants and states: single-account row, multi-account section, search-filtered list, empty list, and empty search result
- Token/component ownership: server list layout lives in `ServerListView.swift`; grouping and identity rules live in `KeyPortCore`

## Accessibility
- Target standard: native macOS accessibility behavior with readable system text and semantic labels
- Keyboard/focus behavior: preserve List selection and toolbar keyboard shortcuts; actions remain available through context menus
- Contrast/readability: do not use color as the sole status signal; pair status colors with text and SF Symbols
- Screen-reader semantics: expose server/account names, aliases, and action help text; keep destructive actions explicit
- Reduced motion and sensory considerations: no required animation or sound

## Responsive behavior
- Supported breakpoints/devices: macOS window resizing from the minimum split-view widths upward
- Layout adaptations: truncate secondary endpoint/alias text before status; keep the status label and selection target stable
- Touch/hover differences: pointer context menus and help tooltips; no touch-only interaction assumptions

## Interaction states
- Loading: show the existing busy indicator and disable conflicting toolbar actions
- Empty: distinguish no servers from no search matches
- Error: keep the selected account visible and surface actionable error text in the existing alert/detail paths
- Success: update the selected account status and alias/configuration state in place
- Disabled: disable account actions when no account is selected or a conflicting operation is busy
- Offline/slow network, if applicable: retain local metadata and show per-account status without hiding the account identity

## Content voice
- Tone: concise, direct, and security-aware
- Terminology: use "服务器端点" for the grouped endpoint and "SSH 用户" or "SSH 账户" for the account; authorization is always account-scoped
- Microcopy rules: prefer action labels that name the target account or alias; avoid repeating server labels in every child row

## Implementation constraints
- Framework/styling system: SwiftUI on macOS 14 with Observation and SwiftPM
- Design-token constraints: use system colors, fonts, controls, and SF Symbols; do not add a parallel design system
- Performance constraints: derive groups from the existing snapshot; do not add a second persistence model for display-only grouping
- Compatibility constraints: preserve `ServerConnection.id` boundaries for Keychain, authorization, CloudKit, and SSH config
- Test/screenshot expectations: run strict build, `./script/test.sh`, `git diff --check`, and bundle launch verification for UI changes

## Open questions
- [ ] Whether a future server-level name should be persisted separately from account records / owner: product / impact: migration and sync scope
