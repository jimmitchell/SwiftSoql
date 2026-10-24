import SwiftUI

/// The plans Salesforce considered for a query, cheapest (the one it uses) first.
struct QueryPlanView: View {
    let result: QueryPlanResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Query Plan")
                .font(.headline)
            Text(result.query)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .textSelection(.enabled)
            if let best = result.plans.first {
                Label(best.relativeCost <= 1
                      ? "Selective: Salesforce uses \(best.leadingOperationType) with a cost of \(Self.cost(best.relativeCost))."
                      : "Not selective: the cheapest plan's cost is \(Self.cost(best.relativeCost)), above 1. On a large SObject this query can be slow or time out; filter on an indexed field to bring it under 1.",
                      systemImage: best.relativeCost <= 1 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(best.relativeCost <= 1 ? Color.green : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Table(result.plans) {
                TableColumn("Operation") { Text($0.leadingOperationType) }
                    .width(min: 70, ideal: 80)
                TableColumn("Cost") { plan in
                    Text(Self.cost(plan.relativeCost))
                        .monospacedDigit()
                        .foregroundStyle(plan.relativeCost > 1 ? Color.orange : Color.primary)
                }
                .width(min: 45, ideal: 50)
                TableColumn("Est. Rows") { Text("\($0.cardinality)").monospacedDigit() }
                    .width(min: 55, ideal: 65)
                TableColumn("Total Rows") { Text("\($0.sobjectCardinality)").monospacedDigit() }
                    .width(min: 55, ideal: 70)
                TableColumn("SObject") { Text($0.sobjectType) }
                    .width(min: 60, ideal: 90)
                TableColumn("Fields") { Text($0.fields.joined(separator: ", ")) }
            }
            .frame(minHeight: 140)
            if !notes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Notes").font(.subheadline.weight(.semibold))
                    ForEach(notes, id: \.self) { note in
                        Text(note)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
            }
            HStack {
                Text("Rows are Salesforce's estimate. Cost is relative to its selectivity threshold of 1.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 640, idealWidth: 700, minHeight: 360, idealHeight: 420)
    }

    /// Salesforce's notes on why it didn't use an index, each once, labeled with the plan.
    private var notes: [String] {
        var seen = Set<String>()
        return result.plans.flatMap { plan in plan.notes.map { "\(plan.leadingOperationType): \($0)" } }
            .filter { seen.insert($0).inserted }
    }

    private static func cost(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...3)))
    }
}
