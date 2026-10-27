import SwiftUI

/// A table of query results with one column per (flattened) field.
///
/// Top-level fields that the user can update are edited in place. When `checkedRows` is given,
/// a first column of checkboxes marks rows for deletion.
///
/// It's an NSTableView (`ResultsTableView`): SwiftUI's Table was slow to scroll through large
/// results, and crashed scrolling down hundreds of columns, as it built every column's cells for
/// each row that came into view.
struct ResultsTable: View {
    let resultSet: ResultSet
    var model: ExplorerModel
    /// The rows checked for deletion, or nil if rows can't be deleted from this table.
    var checkedRows: Binding<Set<ResultRow.ID>>?
    /// How the rows are sorted. Clicking a column header changes it.
    var sortOrder: Binding<[ResultSortComparator]>
    /// Identifies the table for UI tests.
    var accessibilityID = "results"
    /// Called when a subquery cell is clicked.
    var onOpenChild: (QueryResult, String, ResultRow.ID) -> Void = { _, _, _ in }

    var body: some View {
        ResultsTableView(
            resultSet: resultSet,
            model: model,
            editableFields: model.editableFields(in: resultSet),
            isSaving: model.isSaving,
            canChangeData: model.canChangeData,
            checkedRows: checkedRows,
            sortOrder: sortOrder,
            accessibilityID: accessibilityID,
            onOpenChild: onOpenChild
        )
        // A new result set can have entirely different columns, so start the table afresh.
        .id(resultSet.id)
    }
}
