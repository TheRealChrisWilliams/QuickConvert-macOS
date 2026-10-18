# QuickConvert macOS interaction research

Researched 19 October 2026 against Apple documentation and the repositories below. Recommendations are product decisions, not claims of tested macOS behavior. This Windows environment cannot validate Finder delivery, continuous dragging across windows, VoiceOver, Gatekeeper, or trackpad feel.

## Decision

Build a native AppKit status-item drag receiver and a compact conversion panel hosted in AppKit/SwiftUI. The primary action is **drag file to menu bar icon → tray opens → drag over a format → release to convert**. Opening files through the app, dragging into its window or Dock icon, and Choose Files provide equivalent routes.

Apple recommends alternatives to dragging, clear destination feedback, and preservation of copy semantics between apps. A custom conversion panel is justified by its preview, format targets, progress, destination and options; ordinary status-item commands should remain familiar menu actions. Apple generally prefers a menu when clicking a menu bar extra, with an exception for functionality too complex for a menu. Menu bar extras can be hidden by the system, so they cannot be the only entry point. Use a monochrome template mark for the menu bar and a full-color logo for the app. [Apple drag and drop](https://developer.apple.com/design/human-interface-guidelines/drag-and-drop), [Apple menu bar](https://developer.apple.com/design/human-interface-guidelines/the-menu-bar)

## Evidence from actual source

- **Clop:** inspected `DropZone.swift` at commit `4be5106951b490c9b61a53f6f15eb580a760bd69`. It uses separate drop delegates for preset targets, enters/exits to highlight destinations, updates proposals during the drag, and imports items in `performDrop`. This supports the product pattern of target selection during a continuous drag. It is not proof that our status-item-to-panel transition works. Clop has broader background/global event behavior that QuickConvert does not need. Its GPLv3 source is a reference only; do not copy implementation. [Source](https://github.com/FuzzyIdeas/Clop/blob/4be5106951b490c9b61a53f6f15eb580a760bd69/Clop/DropZone.swift), [license](https://github.com/FuzzyIdeas/Clop/blob/4be5106951b490c9b61a53f6f15eb580a760bd69/LICENSE)
- **Settings:** inspected Sindre Sorhus's `Section.swift` and README at commit `f41475771f65379ca10852c95119a7f53f0de5a5`. Its aligned labels, grouped controls and native settings-window conventions are a useful reference for restrained option layout. It has an MIT license; no dependency or copied code is necessary for this small app. [Source](https://github.com/sindresorhus/Settings/blob/f41475771f65379ca10852c95119a7f53f0de5a5/Sources/Settings/Section.swift), [README](https://github.com/sindresorhus/Settings/blob/f41475771f65379ca10852c95119a7f53f0de5a5/readme.md), [license](https://github.com/sindresorhus/Settings/blob/f41475771f65379ca10852c95119a7f53f0de5a5/license)

## Exact interaction contract

These states are the proposed implementation contract:

| State | Input and transition | Visible behavior |
|---|---|---|
| Idle | Click icon, open app, Choose Files, Dock/file-open | Tray with drop area and Choose Files; no conversion starts. |
| Drag entering | A file URL enters status receiver | Immediately reveal tray, show copy cursor, retain drag-session identity; inspect metadata without blocking pointer feedback. |
| Inspecting | Readable files are being identified | Source name/count and short activity indicator; format targets cannot commit until valid. |
| Drag choosing | Pointer enters valid format tile | Highlight exactly that tile with icon, border and text; show destination and relevant caveat. Source is never moved. |
| Drop on format | Release on a valid tile | Revalidate input, freeze format/options, create job once and begin conversion. |
| Drop on neutral tray | Release away from targets | Retain files in Ready state; user can choose format/options and click Convert. |
| Ready | Format click or keyboard selection | Preview, explicit target, destination, options disclosure and Convert button. A click selects; Convert commits. |
| Leaving or Escape | Drag leaves all receivers or is canceled | Clear highlight; do not start work. Allow a short grace interval crossing from icon to tray; dismissal must not interrupt the active drag. |
| Running | Committed job | Source→target, actual progress when measurable, Cancel, and persistent job state even if tray closes. |
| Canceling | Cancel pressed | Stop only this job, wait for worker termination, remove only this job's temporary output, then show Canceled. |
| Complete | Output is finalized and validated | Output name/path, actual size, Reveal in Finder, draggable output and Convert Another. Keep result until dismissed. |
| Failed | Read, write or codec error | Plain-language reason and actionable recovery: Retry, Choose Folder, or Choose Another Format. Diagnostic details are optional. |

AppKit provides enter/update/exit and prepare/perform/conclude destination callbacks, and `NSStatusBarButton` conforms to `NSDraggingDestination`. Use that lifecycle instead of background clipboard polling. Continuous handoff between the status item and newly shown panel remains a real-Mac acceptance gate. A hover must never execute a conversion. [NSDraggingDestination](https://developer.apple.com/documentation/appkit/nsdraggingdestination)

Keep format tiles in stable order for a source family. Prefer a few common targets first and a visible More Formats control; do not reorder under the pointer after probing. Read metadata to suppress impossible operations, including audio extraction from a silent video. For mixed batches, offer only common valid targets and state the count. If batch support is not implemented, reject extra files explicitly rather than silently converting the first.

## Minimum useful options

Use explicit, predictable defaults. Primary tray: source preview/name, format tiles, destination summary, Options disclosure, action/progress/result. Avoid exposing engine names, threads, codec flags or hardware switches in the normal flow.

| Source | Useful controls | Required disclosure |
|---|---|---|
| Images | Target; JPEG/WebP quality preset; original dimensions by default; optional longest-edge resize | JPEG removes transparency: show chosen background color. Animated→still needs an explicit first-frame choice. |
| PDF | PNG/JPEG target; all pages or page range; resolution preset such as Screen/Print | State page count and output folder before exporting many images; never imply a raster conversion keeps selectable text. |
| Audio | Target; lossy bitrate/quality preset; keep channels/sample rate by default | Lossy transcoding can reduce quality; a lossless output cannot restore discarded detail. |
| Video | Target; Original/1080p/720p size; quality preset; optional audio extraction when an audio stream exists | Show whether video is copied or re-encoded when useful; prefer compatible copy when possible. No exact output-size prediction without evidence. |
| All | Beside Original default; Choose Folder; cancellation; reveal/drag result | Collision names must be visible; originals stay intact. Show actual bytes after conversion, even when larger. |

Only ship options wired to real engine behavior. Keep unimplemented ideas in a follow-up list, not as inert controls. Remember destination/quality only if behavior remains clearly visible before the next conversion.

## Progress, trust and failure

Use a determinate bar only when real work units exist: encoded timestamp versus duration, or completed PDF pages versus selected pages. Otherwise use an indeterminate indicator; never invent a smooth percentage. Keep progress in the same tray location, and offer Cancel. Closing the tray must not cancel a running job. [Apple progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators)

Write to unique temporary paths in the chosen destination. Finalize atomically after success where feasible; existing files must not be overwritten. Do not delete source files. Refuse directories, unreadable inputs and unsupported content with useful explanations. Retry permissions failures by offering a folder picker rather than requiring Full Disk Access as general setup. Cancel must leave no misleading completed file, and partial success in a batch must list individual results.

Launch embedded FFmpeg with Foundation `Process`, an absolute executable URL, argument arrays, and `Pipe` capture for stdout/stderr. Run work off the main thread and drain pipes during execution. Do not invoke Terminal, `open -a Terminal`, shell scripts as user-facing tools, or ask users to install Homebrew. Child-process execution does not require a terminal window. Use exit status plus output validation to determine success. [Apple Process](https://developer.apple.com/documentation/foundation/process), [standardOutput](https://developer.apple.com/documentation/foundation/process/standardoutput)

## Accessibility and visual behavior

Use native buttons with useful VoiceOver labels, a logical focus order, keyboard format selection, Return to convert and Escape to dismiss selection UI. Canceling a drag and canceling a running conversion are separate actions. Keep source, target and status available to assistive technology. Targets should be generous; Apple lists 28×28 pt as the default macOS control target guidance. Support system colors, light/dark appearances, Increase Contrast and Reduce Transparency. Never signal hover/success/failure solely through hue. Respect Reduce Motion: replace scale/bounce or travel with a short fade or immediate change. [Apple accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [SwiftUI Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion)

## Finder and distribution

For the first release, use an **NSServices service in the main app bundle** to receive Finder file URLs and open the same tray. This avoids a second extension target. It appears through Services; do not advertise guaranteed Quick Actions placement. Declare supported UTIs in `NSSendFileTypes`, and perform processing asynchronously after returning control to Finder. Registration and user enablement still require testing. [Apple Services properties](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html), [NSServices](https://developer.apple.com/documentation/bundleresources/information-property-list/nsservices)

A separate Finder Action Extension is a valid later route for Preview-pane/Quick Action integration, but Apple documents that new extensions are disabled by default and must be enabled. It adds bundle, lifecycle and activation-rule work without improving the primary drag interaction. [Apple Finder Action Extension sample](https://developer.apple.com/documentation/appkit/add-functionality-to-finder-with-action-extensions)

Ship one self-contained `.app` inside a drag-to-Applications DMG. Use an ad hoc signature for local bundle integrity where appropriate; it does not identify the developer or replace notarization. A downloaded unnotarized app may be blocked until the user deliberately selects Open Anyway in Privacy & Security. Managed Macs may restrict this. Publish clear first-launch instructions without recommending that users disable Gatekeeper. Include licenses/notices for bundled conversion engines and verify the actual FFmpeg build configuration before redistribution. [Apple Gatekeeper instructions](https://support.apple.com/en-us/102445), [FFmpeg licensing](https://ffmpeg.org/legal.html)

Do not promise a universal DMG until both arm64 and x86_64 app and helper slices exist and dependencies are inspected. GitHub Releases can host the DMG; a Pages download page can link to it. A Windows review cannot certify the generated macOS binaries, file-permission behavior or downloaded-app quarantine flow.

## Product acceptance gates

1. On a Mac, complete 20 continuous drags from Finder through status icon to each visible tile without losing the drag or starting twice; include fast/slow movement, screen edges, multiple monitors and a hidden menu bar.
2. Cancel/exit the drag over icon, gap, tray, invalid target and outside; zero outputs may be created. Drop in neutral tray and configure using clicks alone.
3. Complete the same task with keyboard only and VoiceOver; test light/dark, Increase Contrast, reduced transparency and reduced motion.
4. Process large media and a multi-page PDF while interacting with the tray; verify real progress, cancellation, closing/reopening tray, collision names, unwritable destination and corrupted input.
5. Hash sources before/after success, cancellation and failure. Validate output decode, dimensions/pages/duration/audio presence as applicable. No Terminal appears in any launch path.
6. Download release DMG in a clean Mac account with no development tools/Homebrew; approve first launch via documented system UI, drag to Applications, relaunch, open files from Dock/app and verify optional Finder Service registration.
7. Measure cold/warm time to first visible feedback, time until targets are usable, conversion latency, cancellation latency and resource use on real Apple Silicon and Intel hardware. Report medians and tails with file sizes, quality settings and output validation. UI latency targets are design goals until measured; Windows engine benchmarks are not macOS evidence.
