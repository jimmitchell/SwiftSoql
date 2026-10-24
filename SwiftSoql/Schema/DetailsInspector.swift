import SwiftUI

/// Shows the describe properties of the SObject or field selected in the schema sidebar.
struct DetailsInspector: View {
    let model: ExplorerModel
    @AppStorage("hideEmptyDetails") private var hideEmpty = true

    var body: some View {
        Group {
            if let item = model.schemaSelection, let describe = model.cachedDescribe(item.sobjectName) {
                switch item {
                case .sobject:
                    DetailsList(title: describe.name, sections: Self.sobjectSections(describe), hideEmpty: hideEmpty)
                case .field(_, let fieldName):
                    if let field = describe.field(named: fieldName) {
                        DetailsList(title: "\(describe.name).\(field.name)", sections: Self.fieldSections(field), hideEmpty: hideEmpty)
                    }
                }
            } else if model.schemaSelection != nil {
                ProgressView()
            } else {
                ContentUnavailableView("No Selection", systemImage: "sidebar.left", description: Text("Select an SObject or field to see its details."))
            }
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $hideEmpty) {
                    Label("Hide Empty Properties", systemImage: "line.3.horizontal.decrease")
                }
                .help("Hide empty properties")
            }
        }
    }

    // The rows follow SoqlXplorer's details panel.

    private static let sobjectProperties: [(String, String)] = [
        ("Name", "name"), ("Label", "label"), ("Plural Label", "labelPlural"), ("Key Prefix", "keyPrefix"),
        ("Custom", "custom"), ("Custom Setting", "customSetting"), ("Createable", "createable"),
        ("Updateable", "updateable"), ("Deep Cloneable", "deepCloneable"), ("Activateable", "activateable"),
        ("Deletable", "deletable"), ("Undeletable", "undeletable"), ("Mergeable", "mergeable"),
        ("Queryable", "queryable"), ("Retrieveable", "retrieveable"), ("Searchable", "searchable"),
        ("Layoutable", "layoutable"), ("Compact Layoutable", "compactLayoutable"),
        ("Search Layoutable", "searchLayoutable"), ("Replicateable", "replicateable"),
        ("Triggerable", "triggerable"), ("MRU Enabled", "mruEnabled"), ("Feed Enabled", "feedEnabled"),
        ("Has Subtypes", "hasSubtypes"), ("Is Subtype", "isSubtype"), ("Is Interface", "isInterface"),
        ("Implemented By", "implementedBy"), ("Implements Interfaces", "implementsInterfaces"),
        ("Default Implementation", "defaultImplementation"), ("Associate Entity Type", "associateEntityType"),
        ("Associate Parent Entity", "associateParentEntity"), ("Deprecated And Hidden", "deprecatedAndHidden"),
    ]

    private static let fieldProperties: [(String, String)] = [
        ("Name", "name"), ("Label", "label"), ("Type", "type"), ("Soap Type", "soapType"), ("Custom", "custom"),
        ("Help Text", "inlineHelpText"), ("Length", "length"), ("Digits", "digits"), ("Scale", "scale"),
        ("Precision", "precision"), ("Byte Length", "byteLength"), ("High Scale Number", "highScaleNumber"),
        ("Default Value", "defaultValue"), ("Encrypted", "encrypted"), ("Createable", "createable"),
        ("Updateable", "updateable"), ("Cascade Delete", "cascadeDelete"), ("Restricted Delete", "restrictedDelete"),
        ("Defaulted On Create", "defaultedOnCreate"), ("Calculated", "calculated"), ("AutoNumber", "autoNumber"),
        ("Unique", "unique"), ("Case Sensitive", "caseSensitive"), ("Name Pointing", "namePointing"),
        ("Sortable", "sortable"), ("Groupable", "groupable"), ("Aggregatable", "aggregatable"),
        ("Permissionable", "permissionable"), ("External Id", "externalId"), ("ID Lookup", "idLookup"),
        ("Filterable", "filterable"), ("HTML Formatted", "htmlFormatted"), ("Name Field", "nameField"),
        ("Nillable", "nillable"), ("Compound Field Name", "compoundFieldName"), ("Mask", "mask"),
        ("Mask Type", "maskType"), ("Extra Type Info", "extraTypeInfo"), ("Reference To", "referenceTo"),
        ("Relationship Name", "relationshipName"), ("Polymorphic Foreign Key", "polymorphicForeignKey"),
        ("Reference Target Field", "referenceTargetField"), ("Dependent Picklist", "dependentPicklist"),
        ("Controller Name", "controllerName"), ("Restricted Picklist", "restrictedPicklist"),
        ("Query By Distance", "queryByDistance"), ("Value Formula", "calculatedFormula"),
        ("Default Formula", "defaultValueFormula"), ("Formula Treat Null as Zero", "formulaTreatNullNumberAsZero"),
        ("AI Prediction Field", "aiPredictionField"), ("Deprecated And Hidden", "deprecatedAndHidden"),
        ("Search Prefilterable", "searchPrefilterable"), ("Relationship Order (CJOs)", "relationshipOrder"),
        ("Write Requires Read on Master (CJOs)", "writeRequiresMasterRead"),
        ("Display Location in Decimal", "displayLocationInDecimal"),
    ]

    static func sobjectSections(_ describe: SObjectDescribe) -> [DetailsSection] {
        var sections = [DetailsSection(title: nil, rows: rows(sobjectProperties, from: describe.json))]
        let urls = describe.json["urls"]
        sections[0].rows += [("URL for Edit", "uiEditTemplate"), ("URL for Detail", "uiDetailTemplate"), ("URL for New", "uiNewRecord")]
            .map { DetailsRow(label: $0.0, value: urls?[$0.1]?.string ?? "") }
        if !describe.childRelationships.isEmpty {
            sections.append(DetailsSection(
                title: "Relationships to \(describe.name)",
                rows: describe.childRelationships.map {
                    DetailsRow(label: "\($0.childSObject).\($0.field)", value: $0.relationshipName ?? "")
                }
            ))
        }
        return sections
    }

    static func fieldSections(_ field: FieldDescribe) -> [DetailsSection] {
        var sections = [DetailsSection(title: nil, rows: rows(fieldProperties, from: field.json))]
        let picklist = field.picklistValues
        if !picklist.isEmpty {
            sections.append(DetailsSection(
                title: "Picklist Values",
                rows: picklist.map { DetailsRow(label: $0.value, value: $0.active ? $0.label : "\($0.label) (inactive)") }
            ))
        }
        return sections
    }

    private static func rows(_ properties: [(String, String)], from json: JSONObject) -> [DetailsRow] {
        properties.map { label, key in DetailsRow(label: label, value: format(json[key])) }
    }

    /// Formats like SoqlXplorer: true is "Yes", false and zero are blank.
    private static func format(_ value: JSONValue?) -> String {
        switch value {
        case .bool(let b): b ? "Yes" : ""
        case .number(let n): n == "0" ? "" : n
        case .string(let s): s
        case .array(let items): items.compactMap(\.displayText).joined(separator: ", ")
        case .null, .object, .none: ""
        }
    }
}

struct DetailsSection: Identifiable {
    var title: String?
    var rows: [DetailsRow]
    var id: String { title ?? "" }
}

struct DetailsRow: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

private struct DetailsList: View {
    let title: String
    let sections: [DetailsSection]
    let hideEmpty: Bool

    var body: some View {
        List {
            Text(title)
                .font(.headline)
                .textSelection(.enabled)
            ForEach(sections) { section in
                let rows = hideEmpty ? section.rows.filter { !$0.value.isEmpty } : section.rows
                if let title = section.title {
                    Section(title) { rowViews(rows) }
                } else {
                    rowViews(rows)
                }
            }
        }
    }

    private func rowViews(_ rows: [DetailsRow]) -> some View {
        ForEach(rows) { row in
            LabeledContent(row.label) {
                Text(row.value)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}
