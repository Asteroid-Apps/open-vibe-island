# T3 Code integration verification

Verified on macOS on 2026-11-24 against installed T3 Code 0.1.10. The verification covers the native adapter and the sidebar/UI follow-ups recorded below.

## Automated checks

187 tests passed across 12 targeted suites. The final run enabled the opt-in
live T3 snapshot/stream test:

```sh
OPEN_ISLAND_TEST_T3_LIVE=1 swift test --filter 'T3|SessionStateTests|TerminalJumpServiceTests|AgentSessionPresentationTests|AppModelSessionListTests|HookSkipConfigurationTests|CodexSessionTrackingTests|CodexInternalSessionFilterTests'
```

Coverage includes native interaction decoding, local-origin validation, safe
identifier encoding, project enrichment versus authoritative snapshots,
startup cache merging, retained-history filtering, reconnects, pending-control
identity, native approval choices, secret-request handoff, multi-select answers,
session settlement, source-specific hook deduplication, and thread navigation.

## Installed-app checks

The signed `~/Applications/Open Island Dev.app` was built using
`scripts/launch-dev-app.sh --skip-setup`. Its signature verifies with the stable
local `Open Island Dev Local` identity. The Homebrew `open-island` cask and
`/Applications/Open Island.app` were removed without using `--zap`.

Existing production preferences were backed up and imported into the dev app's
preference domain before launch. Application support and agent configuration
backups were retained outside the repository. The completion-reply preference
was enabled temporarily for testing and restored to its original disabled
setting. Replies remain available through General → Reply from completion card.

Computer use verified:

- Setup reports a native T3 connection; disabling and re-enabling it reconnects.
- A real delegated T3 question appears in Open Island. Selecting and sending
  `Native round-trip` resumes the child, which responds
  `Native T3 question round-trip verified: Native round-trip`.
- A reply sent from the expanded completion row starts another native T3 turn.
  The child responds `Native T3 completion reply verified`.
- The explicit per-thread navigation button opens the exact parent conversation.
- The same button opens the exact delegated conversation, including its encoded
  identifier. T3 displays both the question answer and subsequent reply result.

The disposable child completed both turns with no pending requests and was
settled after verification. No repository files were changed by the child.

## Limits of verification

The actual approval/deny prompt was covered through protocol and coordinator
tests, rather than a model-driven live permission request. Secret and user-only
requests deliberately continue in T3 Code. Other providers and SSH/relay-only T3 environments were not live-tested.
Saved direct/container environments are covered in the follow-up below.
The native protocol may change in future T3 versions.


## Sidebar visibility follow-up

The island now follows T3 sidebar placement rather than a recency window:
settlement always removes a thread, even while running or awaiting approval.
Unsettled sidebar threads stay visible regardless of age, with native idle and
completed states preserved. Hidden subagents and side chats are excluded;
snoozed threads remain hidden unless a request wakes them.

133 targeted tests across nine suites passed, including the live native
snapshot/stream check. New regressions verify settlement removes the row from
both active and recent lists, unsettling restores it, old completed threads
remain visible, idle threads retain idle presentation, and hidden child/snoozed
threads are excluded. The installed dev bundle was rebuilt from this follow-up.

## Completion read-state follow-up

143 targeted tests across 11 suites passed, including live T3 snapshot/stream
reading. Completed results remain done until T3's `lastVisitedAt` is at or after
`latestRunCompletedAt`; viewed results remain visible as idle. A visit during a
run does not acknowledge a later completion, and another completed run becomes
unread again. Read updates invalidate completion notification cards without
emitting another completion event. Missing/invalid timestamps preserve done.

The regression suite covers the full running → done → viewed/idle → running →
done cycle, equal timestamps with different ISO precision, invalid/missing read
metadata, notification eligibility, and decoding the native timestamps.

### Foreground acknowledgement

Newly observed completions now remain unread when T3 auto-visits a selected chat
in a background window. The adapter checks the frontmost application and the
focused T3 window's web-area URL, matching both environment and thread IDs.
Returning to that exact chat acknowledges it within one second, even if T3
doesn't emit another visit update. Another chat/window/environment cannot clear
it. Previously read history remains idle when the adapter first connects.

This uses macOS Accessibility access without reading conversation elements.
Traversal stops at the web area and is bounded in depth and breadth. Settings →
Setup → T3 Code offers “Allow focused-chat detection…” when access is missing;
no permission prompt is triggered automatically. If the window identity cannot
be read, newly observed completions remain done. The unread latch currently
lives in the connected adapter; restarting the app restores T3's historical read
state rather than reconstructing which window was foreground in the past.

Regression coverage includes background auto-visits, returning without a new
visit event, wrong-chat/environment focus, subsequent runs, initial history,
and completion event deduplication. The optional native focus probe is enabled
with `OPEN_ISLAND_TEST_T3_FOREGROUND_URL` set to the currently focused chat's
`t3code://app/#/<environment>/<thread>` URL. Its test host must have Accessibility
access; the local command-line test host lacked it during verification. Computer
use confirmed that the installed T3 window exposes the expected exact chat URL.
All 62 T3 tests across ten suites passed with the optional live focus probe
disabled. The six read-state tests were rerun after the final reader guards;
the signed dev app was rebuilt, installed, and its native T3 connections checked.


## Sidebar loading performance follow-up

The previous snapshot loop awaited a full thread projection for every new row,
serially, before publishing that row. This made the list fill one agent at a time
and blocked processing of subsequent shell events. The adapter now publishes the
whole sidebar from its shell data immediately, skips full transcripts when
completed/idle history already has a message preview, and hydrates missing
previews and active/request/completion details in the background with a
four-request limit.

37 targeted T3 tests passed, including the installed local server's authenticated
snapshot and WebSocket stream. New regression tests hold every detail response
open while verifying all 12 agents are already present, enforce the four-request
limit, ensure delayed responses cannot undo newer status/settlement, preserve
hydrated question controls during shell-only updates, and verify initial completed
history with a preview makes no detail requests while missing previews
hydrate after the row appears.

The full suite was attempted but crashed in the existing keystroke injector test
with `NSScreen reconfig must only happen on the main thread`; the targeted T3
suites pass independently. The installed development app was rebuilt for manual
verification.


## Assistant previews and saved environments follow-up

List rows render the latest nonempty assistant message without a card or tool
preview, at most six visual lines. Empty messages do not erase the previous
assistant update, and missing messages do not leave an empty panel. Native
question/approval controls and enabled completion replies remain available.

The adapter also reads T3 Desktop's encrypted connection catalog through macOS
Keychain and connects to enabled saved direct bearer routes. Each environment
retains its own stream, session namespace, and action routing. Borrowed desktop
credentials are held in memory and never revoked or persisted by Open Island.
The safeStorage decoder follows the [Chromium macOS v10 format](https://chromium.googlesource.com/chromium/src/+/refs/tags/143.0.7497.1/components/os_crypt/sync/os_crypt_mac.mm).
Only catalog changes trigger another Keychain read; polling and networking run
away from the main UI thread. Saved SSH-only/relay-only routes are outside this
adapter's supported direct transports.

Live checks read the configured test environment's snapshot, thread details,
and WebSocket stream. Disconnect/reconnect confirmed the desktop credential was
not revoked. The parent coordinator surfaced a container thread with its native
environment ID and detached it independently when its saved route was removed
from the test coordinator. This did not modify T3's catalog or any thread.
46 targeted T3 tests passed, including those live checks. Automated regressions
cover human-message selection, empty message handling, known encrypted fixtures,
disabled environments, and unsafe/mismatched URLs.


The rebuilt, signed development app was inspected with native computer use.
All expected sidebar agents appeared, including a container thread. The
rows showed live assistant commentary/final messages without card backgrounds;
a long container response visibly truncated at six lines. Clicking its row
opened the matching container environment/thread in T3 Desktop, and its viewed
completion displayed idle. Local active rows retained live commentary previews.


## Shared list and attention row follow-up

The separate notification rendering path was removed, including its completion
card, nested scrolling message area, and tool-call preview. Both list and
attention surfaces now instantiate the same row with the same title, status
indicator, six-line assistant message, and native actions. Per-agent durations
are removed; titles fill the available width, and message text starts at the
same horizontal position as the title for each status-indicator style.

The app build and 32 targeted presentation/surface tests passed. The deterministic
`longCompletionCard` smoke scenario passed and its rendered artifact showed an
unboxed assistant preview with no duration and matching title/message left edges.


## Project icons and trailing status follow-up

Each shared row now puts project identity on the left and status on the right.
T3's native `projectIcon` union (Lucide, emoji, monogram) and selected color flow
through project snapshots/updates into session metadata. The default monogram
normalizes Unicode, prefers digits in names, and uses T3's deterministic
18-color hash. Text remains aligned under the title after the project icon.

Lucide geometry and legacy aliases are bundled from the installed T3 0.1.10
client as a 1.1 MB multipage vector PDF, with its license. The dark-mode palette
comes from the same client's CSS. AppKit/PDFKit render these cached assets;
there is no browser or Python dependency at runtime. To regenerate the assets,
install ReportLab and svglib into an isolated Python environment and run
`scripts/generate-t3-project-icons.py --asar /path/to/app.asar`.

Projects without explicit icons use the native `assets.createUrl` favicon
service, asynchronously and once per project appearance. Asset downloads retain
same-origin authentication/redirect restrictions, with a 2 MB decoded-data cap.
The existing monogram appears immediately while discovery runs. Project icon
and favicon updates preserve the most recently hydrated assistant message and
pending native controls.

51 targeted T3 tests passed with live local/container favicon, snapshot, and
stream checks enabled. Further targeted rendering checks passed, including
transparent backgrounds and visible vector strokes, picker/legacy Lucide names,
Unicode/default color fixtures, old snapshot compatibility, metadata round-trips,
and project updates while a question is pending.


Native computer use verified fallback monograms and explicitly selected Lucide
icons and colors in both local and container projects.
Each status indicator appeared at the right edge of the title row, with the
assistant message aligned under the title. Vector transparency/stroke rendering
and icon aliases also passed targeted native image tests.


## Status priority and running spinner follow-up

Running rows use a gray dashed ring rotating continuously, with no glow. Idle
rows omit the status view and its reserved space. Shared status classification
orders the attention list and state sections as approval, answer, unread done,
running, idle. Within each class, latest event time sorts first, then title and
stable identity break ties. T3's viewed completions move into idle independently
of terminal-session age preferences.

62 targeted presentation, read-state, surface, and session-list tests passed.
New regressions exercise every status twice with event times deliberately opposed
to priority, local/container identities, deterministic ties, and the unread-done
→ viewed/idle transition. Existing explicit last-update sorting and the never-stale
preference continue to pass.


Native computer use confirmed unread green completions sort above running gray
rings. Successive captures showed spinner rotation, while an idle container
entry had no status indicator or reserved indicator slot.


## Native waiting-work follow-up

The adapter previously used only the latest run's status, losing the distinction
between a completed run and a thread that still waits on commands or subagents.
It now decodes native activity status, blocked-thread waits, background tasks,
and monitor-wake state. Active runs, awaited commands, pending subagents/tasks,
and progress-monitor wakes keep the thread in the running presentation and
priority class. Persistent servers and passive PR watches do not falsely hold
a completed thread open.

Changes in background work alone can move a thread back from done to running,
even when the latest run ID/status are unchanged. Completion and unread-result
metadata are withheld until the work clears, with completion notification deduplication
retained. Native user questions and approvals remain distinct attention states.
Completion reply dispatch is also blocked while background work is still active.

102 targeted tests passed with live local/container snapshot, stream, and asset
checks enabled. New regressions cover native wire decoding and older servers,
completed latest runs with active work, command/subagent holds, passive servers,
monitor wakes, native waiting presentation/ordering, and exactly one completion
after all waiting work finishes.


Native computer use confirmed the live mismatch is resolved: T3 Desktop's
sidebar showed a test thread as Waiting, and the rebuilt Island showed that same
thread with the gray running spinner and muted title in the running group,
rather than the green completed state.


## Quiet closed notch follow-up

The runtime closed surface no longer mounts the equalizer, center label, or
agent-count/grid content. Its visual width and mouse hit area match the physical
notch; the former 44-point wings and popping expansion budget are removed. On a
non-notched display the empty placeholder is 70 points wide. Hover opening uses
the same existing monitor and delay, now with the narrower target. Nearby
menu-bar points outside the notch no longer qualify as a closed-surface hit.

27 targeted closed-pill, overlay geometry, and notch-interaction tests passed,
including matching physical width, payload-independent quiet width, no popping
widening, and rejection of mouse points in the former side wings.


Native computer use verified the installed signed bundle's empty notch-width
closed surface, with no glyph/count exposed in accessibility. Opening showed
the existing agent list, and Escape returned to the quiet closed notch.
