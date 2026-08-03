# Table semantics audit

**Status:** source audit on 2026-08-03. This is an actionable choice record, not
visual acceptance. No build, test, VM, Docker, or live-window interaction was run for
this audit.

## Decision rule

The user task comes first. Retain a `Table` only for a collection of peer records that
need multiple stable attributes, native selection, sorting, or a contextual action.
Use `List(selection:)` plus `OutlineGroup` when the task is to traverse an actual
parent → child relationship and selected-record facts belong in an inspector. Retain a
`Table(children:)` outline only when that hierarchy also needs multi-column comparison.
Use a `Form`, document editor, log viewport, chart, or `ContentUnavailableView` when it
better owns the task. Never replace an appropriate native table with cards or hand-built
rows.

Consulted: Apple's [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables),
[Outline views](https://developer.apple.com/design/human-interface-guidelines/outline-views),
SwiftUI [`Table`](https://developer.apple.com/documentation/swiftui/table),
[`Form`](https://developer.apple.com/documentation/swiftui/form), and
[`ContentUnavailableView`](https://developer.apple.com/documentation/swiftui/contentunavailableview).
The binding detail is in the [native macOS playbook](NATIVE-MACOS-PLAYBOOK.md#choose-the-content-form-not-a-house-style).

## Inventory

| Source | Current task/data shape | Decision | Required follow-through |
| --- | --- | --- | --- |
| `Views/Containers/ContainersRootView.swift` | Compare peer containers by name, project, image, state, ports, and age; select one for actions/details. | **Retain `Table`.** This is the core dense operational-record case. | Keep the inspector as the place for rich metadata and verify bordered system-table appearance in a current full window. |
| `Views/Containers/ContainerStatsTab.swift` — network samples | Reveal exact timestamped receive/send values behind the throughput chart. | **Retain `Table` as the chart’s tabular equivalent.** | Keep it a compact disclosure, not the primary statistics layout; the chart and table must derive from the same real samples. |
| `Views/Containers/ContainerStatsTab.swift` — scalar samples | Reveal exact timestamp/value pairs behind a CPU or memory chart. | **Retain `Table` as the chart’s tabular equivalent.** | Preserve the accessible label and avoid converting it into a card or synthetic log. |
| `Views/Images/ImagesRootView.swift` | Compare local images by repository, tag, ID, size, age, and use; select one. | **Retain `Table`.** Tagged and dangling groups are labeled sections, not a hierarchy. | Recheck the system bordered style with a real current bundle; only use a section when both actual groups exist. |
| `Views/Builds/BuildsRootView.swift` — cache | Compare flat BuildKit cache records. | **Retain `Table`.** | Keep cache and history as separate collections; do not infer history from cache. Review automatic table appearance in the native window. |
| `Views/Builds/BuildsRootView.swift` — history | Compare completed Buildx history records. | **Retain `Table`.** | Keep the system inspector and direct unavailable state for details/logs rather than placing them in cells. |
| `Views/Volumes/VolumesRootView.swift` | Compare named volumes by driver, size, and use; select for inspection/export/removal. | **Retain `Table`.** | Preserve context-menu and inspector behavior; empty/filter states remain direct unavailable views. |
| `Views/Networks/NetworksRootView.swift` | Compare peer Docker networks by kind, driver, scope, and attachment count. | **Retain `Table`.** | Preserve context menu/inspector selection; no dashboard or network-map substitute is justified. |
| `Views/Disk/DiskRootView.swift` | Review storage-category facts and the largest individual resources without implying aggregates are additive. | **Retain the sectioned `Table`, not an outline.** The rows share stable size/reclaimability columns; sections make the two non-peer sets explicit. | Keep aggregate and resource sections distinct, and verify the system table does not look like an empty-band dashboard at real data densities. |
| `Views/Stacks/StacksRootView.swift` | Traverse actual Compose project → service relationships; inspect one selected record’s facts or run contextual actions. | **Use `List(selection:)` + `OutlineGroup`, not `Table(children:)`.** The real-window observation showed the table’s unoccupied rows as repeated horizontal bands, while the task does not require side-by-side service comparison. | Keep the native disclosure/keyboard selection, row context menu, inspector `Form`, search filtering, source-editor boundary, and destructive confirmation. Recheck the current bundle in light/dark and narrow widths. |
| `Views/Kubernetes/KubernetesRootView.swift` — pods | Compare flat pod records by namespace, phase, readiness, restarts, node, and age. | **Retain sortable `Table`.** | Keep selection, context menu, and inspector description load separate from the list. |
| `Views/Kubernetes/KubernetesRootView.swift` — nodes | Compare flat node records by readiness, role, version, and age. | **Retain sortable `Table`.** | Keep node inspection in the system inspector; no tree is present in this data. |
| `Views/Kubernetes/KubernetesRootView.swift` — recent events | Scan recent event records by reason, message, type, count, and last observation. | **Retain compact `Table`.** It supports cross-event comparison; it is not a container-log stream. | Keep the existing loading/error/empty states in the inspector and constrain the retained-event limit truthfully. |
| `Views/Migration/MigrationRootView.swift` — runtime inventory | Compare local container runtimes and their readiness/count/storage facts. | **Retain selectable `Table`.** | Keep full runtime metadata in the inspector `Form`; it is read-only discovery, not configuration. |
| `Views/Migration/MigrationRootView.swift` — named-volume eligibility | Compare source volumes, drivers, eligibility, and reasons for one selected runtime. | **Retain compact `Table`.** | Keep it read-only in the inspector and use an unavailable view for no reported volumes. |
| `Views/Migration/MigrationRootView.swift` — image selection | Select exact peer image records for a scoped import. | **Retain multi-select `Table`.** | Leave selection initially explicit rather than selecting all; the surrounding `Form` supplies scope/safety facts. |
| `Views/Migration/MigrationRootView.swift` — prepared images | Review the exact image set rederived before an import. | **Retain read-only `Table`.** | Keep the review `Form` for effects and limits; table rows must not become editable commands. |
| `Views/Migration/MigrationRootView.swift` — image report | Compare per-image result, verification, archive size, and detail after import. | **Retain report `Table`.** | Keep retry as a scoped sheet command, not an inline action column. |
| `Views/Migration/MigrationRootView.swift` — volume selection | Select exact eligible named volumes for a scoped transfer. | **Retain multi-select `Table`.** | Retain initially empty selection and the surrounding safety `Form`. |
| `Views/Migration/MigrationRootView.swift` — prepared volumes | Review the exact revalidated volume set before transfer. | **Retain read-only `Table`.** | Keep effects, consent, and safety limits in the review `Form`, outside the table. |
| `Views/Migration/MigrationRootView.swift` — volume report | Compare per-volume outcome, destination state, archive size, and detail. | **Retain report `Table`.** | Keep follow-up guidance in the `Form`; do not present an operation result as a log/card collection. |

## Result

The remaining 20 `Table` uses have a task-shaped native justification. `Stacks` is the
one hierarchy that now uses a system `List` + `OutlineGroup`: its primary task is
traversal, while the inspector owns service facts. The two chart sample tables remain
required exact-value alternatives; configuration, source editing, logs, empty states,
and selected-record facts use their respective system patterns outside tables.

The remaining risk is visual and behavioral acceptance, not a missing generic
container: evaluate each route in a current full window at normal and narrow widths,
in light/dark appearance, with keyboard selection, context menus, inspector
transitions, and VoiceOver. A system table that still produces an empty-band/skeleton
appearance at the tested density must be corrected by choosing a different system
presentation for that specific task—not by styling rows or reviving a custom design
system.
