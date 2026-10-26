# Follow-up notes

## 1. Results table lags with many records and columns

Seen on a real org: the query results window gets sluggish with large result sets and wide queries.

### Why

`ResultsTable` (`SwiftSoql/Results/ResultsTable.swift`) is a SwiftUI `Table` with one column per field from
`TableColumnForEach`. It's backed by `NSTableView` and reuses rows, but every cell is a separately hosted
SwiftUI view, and:

- SwiftUI compares the whole `resultSet.visibleRows` array whenever `ResultSet` changes (checking a row, a
  save, the highlighted row).
- Lots of dynamic columns plus `TableColumnCustomization` is a known weak spot for scrolling and resizing.

The cells make it worse:

- [ ] **Editable cells are live controls, not text** (`ResultsTable.swift` `cell(_:column:)`). Any query
      with `Id` draws updateable fields as a `FieldEditor`: a `TextField` with `@State`/`@FocusState`/
      `onChange` (`CellEditors.swift` `EditableCell`), a `Menu` for picklists, a text field plus hover
      tracking for dates. Probably the biggest single cost.
- [ ] **Every visible cell watches `ExplorerModel`.** Cells read `model.isSaving` and call
      `model.editableField(...)` (reads `isLocked` and the schema cache), so each save redraws the whole grid
      twice.
- [ ] **Column widths are recalculated on each redraw.** `ResultSet.idealWidth(for:)` scans 100 rows per
      column every time the table's `body` runs (about 5,000 lookups at 50 columns).
- [ ] **Every cell has a tooltip** (`.help(...)`).
- [ ] Minor: `column.split(separator: ".")` runs per cell; `tableColumns` is rebuilt every `body`.

### Options

**A. Keep SwiftUI `Table`, make cells cheap** (smaller, less risky; try first)

- Draw every cell as plain `Text`; swap in `FieldEditor` only for the cell being edited (e.g. on
  double-click).
- Work out editable columns and ideal widths once per result set, not per cell or per redraw.
- Pass cells plain values instead of `model`, so `isSaving` doesn't redraw everything.

**B. Wrap `NSTableView` in an `NSViewRepresentable`** (best performance; do this if A isn't enough, or if
>10k rows / 50+ columns is common)

- Add columns with `addTableColumn` when the results change.
- Data source supplies values on demand, so there's no full-array diff.
- Reused plain `NSTextField` cells; AppKit's built-in editing on double-click.
- Sorting via `sortDescriptors`; column hiding and reordering are built in.
- Same pattern already used in `SchemaSidebar.swift` (`NSOutlineView`) and `SOQLTextView.swift`.

Must keep working either way: checkbox column, error column, subquery link cells, picklist/date/boolean
editing, context menu, copy, sort, filter, highlighted row, inspector following the selection, the
`results` / `childResults` accessibility IDs used by UI tests.

### Confirm first

Profile on macOS with the SwiftUI template in Instruments: scroll a large *editable* result (query with
`Id`) and look at view body updates and the hitches track. Re-measure after each change.

## 2. "Describe every SObject after connecting" should be off by default

New installs should start with it disabled; users turn it on if they want it.

- [ ] `SwiftSoql/SwiftSoqlApp.swift`: registered default `"describeAllInBackground": true` → `false`.
- [ ] `SwiftSoql/Settings/SettingsView.swift`: `@AppStorage("describeAllInBackground") ... = true` → `false`
      (keep it matching the registered default).
- [ ] `SwiftSoql/Schema/SchemaCatalog.swift` reads it via `AppDefaults.store.bool(forKey:)`, so no change
      needed there.
- [ ] Maybe update the setting's `Note` text to say it's off by default and what you gain by turning it on
      (the sidebar filter finding fields in every SObject).
- [ ] UI tests already pass `-describeAllInBackground NO`; that can stay or go.
- [ ] Check whether anything relies on it being on, e.g. the sidebar field filter or completions expecting
      every describe to be cached. With it off, filtering by field name only finds SObjects already
      described.

Heads-up: changing the registered default also turns it off for **existing** users who never touched the
setting. Anyone who explicitly switched it on keeps it on. If existing users should keep their current
behavior, that needs a one-time migration (e.g. write `true` for users upgrading from a version before this
change).

See section 3: once describe-all is optimized, it may be fine to leave it on by default.

## 3. Describe-all crashes the app on large orgs

Seen on a real org with many SObjects and fields. Crash report from 2026-10-26 (version 1.8 (9), macOS 26.7.1,
M4 Max, 64 GB) is analyzed below.

### What the crash report shows

- **Not out of memory.** About 194 MB of heap at the time, on a 64 GB Mac. `EXC_BAD_ACCESS (SIGBUS)`, not a
  memory-limit termination.
- **Not the sidebar or a hang.** The main thread was working normally: SwiftSoql code in an async task was
  changing an observed property (`ObservationRegistrar.withMutation`) and SwiftUI was scheduling a redraw.
- **Memory corruption in Swift's async task machinery.** The crash is on a background task thread
  (thread 5, `com.apple.root.user-initiated-qos.cooperative`), in `completeTaskWithClosure`. When a task
  finishes, the runtime jumps to a stored "continue here" address. That address pointed into heap data
  (`MALLOC_SMALL`), so the processor refused to run it ("Instruction Abort, Permission fault"). The record
  holding it had been overwritten or freed. Usual causes: a data race, a continuation resumed twice, or a
  compiler/runtime bug.
- **Timing fits describe-all.** Crashed 17 seconds after launch (connect + background describes). Child
  tasks of a task started on the main thread run on that kind of thread. The main thread at the same moment
  matches `describeAll`'s loop adding results to `describes`.

### Main suspect: the task group in `describeAll`

- `SchemaCatalog.describeAll` (`SwiftSoql/Schema/SchemaCatalog.swift`) runs three requests in a
  `withTaskGroup`. Each child sends back a large result: a tuple holding a `Result` with arrays of
  `SObjectDescribe`.
- The project weakens the compiler's protection here:
  - **Swift 5 language mode** (`SWIFT_VERSION = 5.0`): data races and unsafe hand-offs between threads
    aren't compile errors.
  - **Main-actor default isolation + approachable concurrency** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`,
    `SWIFT_APPROACHABLE_CONCURRENCY = YES`): these change where closures and async functions run in ways
    that are easy to get wrong without strict checking.
- Less likely: `SFCLI.runProcess` (captured `errData` written on another queue) and `withTimeout` in
  `SFCLI.swift`. Both run at connect time but finish before describes start.
- There are forum reports of similar `EXC_BAD_ACCESS` crashes in task groups, but none clearly matches:
  - <https://forums.swift.org/t/taskgroup-related-crash/56425>
  - <https://developer.apple.com/forums/thread/703448>
  - <https://forums.swift.org/t/exc-bad-access-using-withtaskgroup-depending-on-size-of-data/54506>
  - <https://github.com/swiftlang/swift/issues/75771>

### Pin it down (do these first)

- [ ] **Turn off "Describe every SObject after connecting" and connect to the same org.** If the crash goes
      away, describe-all is confirmed. This is also the workaround for now.
- [ ] **Symbolicate the SwiftSoql frames on the main thread.** Need the dSYM for 1.8 (9), UUID
      `46EFCF59-F550-30DB-8C50-053D50820728`, from the Xcode archive:
      ```
      mdfind "com_apple_xcode_dsym_uuids == 46EFCF59-F550-30DB-8C50-053D50820728"
      atos -arch arm64 -o SwiftSoql.app.dSYM/Contents/Resources/DWARF/SwiftSoql -l 0x102130000 \
        0x10215f8b4 0x102166810 0x102139079 0x1021668bd 0x102291ce5 0x1021ba101 0x102206485
      ```
      This names the function that was changing the observed property.
- [ ] **Run a Debug build against the large org with Thread Sanitizer, then separately with Address
      Sanitizer** (Xcode can't enable both at once). TSan reports a data race when it happens; ASan catches
      use of freed memory at the point of use.
- [ ] **Set Strict Concurrency Checking to Complete** (or move to Swift 6 mode) so real data races show up
      at compile time.

### Likely fix

If describe-all is confirmed: replace the task group with one batch at a time, and keep the fetching and the
reduction to a field-name index inside `SalesforceClient`, so only a small, simple result comes back to the
main thread. This removes the suspect code and is also the first two items under "Optimizations" below.

### Optimizations (still worth doing; not the crash cause)

From reading the code, before the crash report. Memory and main-thread work will still hurt on large orgs
once the crash is fixed.

What's expensive now:

1. **Every full describe is kept, for every object.**
   - `describeAll` stores a complete `SObjectDescribe` per object, including the raw describe JSON.
   - `SObjectDescribe.pruned` (`DescribeModels.swift`) only drops empty properties; picklist values,
     dependent-picklist `validFor` data, etc. are all kept.
   - Each JSON value is its own small allocation, so in-memory size is several times the download size.
   - Large orgs with managed packages: 3,000–5,000 SObjects, many generated (`*Share`, `*History`, `*Feed`,
     `*ChangeEvent`).
   - Three 25-object composite requests in flight at once; each response is copied to `[UInt8]` and parsed in
     full before pruning, so memory spikes.
2. **The sidebar builds a row for every field of every described object.**
   - `SchemaOutline.Coordinator.update` (`SchemaSidebar.swift`) calls `children(of:)` for each newly described
     object and `reloadItem`s it, even when collapsed.
   - With describe-all that's hundreds of thousands of `Node` NSObjects, created on the main thread.
   - A filter or sort change rebuilds all of them, sorting fields again when sort is on.
3. **Every describe that arrives triggers app-wide recalculation on the main thread.**
   - `describes` is observed, so every view that called `cachedDescribe` redraws on each insert, including
     every results-table cell (via `editableField`).
   - `SchemaSidebar.body` rebuilds `describedNames` by checking every SObject on each update.
   - With filter text entered, `ExplorerModel.filteredSObjects` runs `localizedCaseInsensitiveContains` over
     every field of every described object on each keystroke and each new describe.
4. **Each window has its own catalogs**, so two windows on one org hold two full copies.

Fixes, in order:

- [ ] **Keep a small field-name index for describe-all.** The sidebar filter only needs field names: store
      e.g. `[sobject: [fieldName]]` for background describes. Keep full `SObjectDescribe`s only for objects
      expanded, queried or edited, with a size limit on that cache. Build the index inside `SalesforceClient`
      so the full response is freed straight away.
- [ ] **One batch at a time** (or fewer than 25 describes per request) instead of the task group. Also the
      crash fix above.
- [ ] **Skip objects nobody needs.** Describe only queryable ones (`allQueryableSObjects` exists); consider
      skipping `*Share`, `*History`, `*Feed`, `*ChangeEvent`. Can halve the work.
- [ ] **Save the index to disk between launches**, per org + API version. Refresh with `If-Modified-Since`
      (describe supports it, including as a composite subrequest header), so reconnecting costs almost
      nothing and uses far fewer API requests.
- [ ] **Less main-thread work:**
  - Create sidebar field nodes only when an object is expanded.
  - Make `describes` `@ObservationIgnored`; publish one change counter per round of batches.
  - Keep the field-name index lowercased so filtering needs no locale-aware comparison; debounce the
    filter field.
- [ ] **Share one schema catalog per org across windows.**
