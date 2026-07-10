import SharibakoCore
import SwiftUI

/// The left column: every scope in the vault, sectioned by `ScopeType`.
///
/// Pure rendering — grouping and ordering live in `WorkshopModel.scopeSections`
/// (Decision 8 keeps branching logic out of `View` structs). Selection binds to
/// the model's `selectedScopeID`; AT-02's secret list reads it.
struct ScopeSidebar: View {
    @Environment(WorkshopModel.self)
    private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selectedScopeID) {
            ForEach(model.scopeSections) { section in
                Section(section.title) {
                    ForEach(section.scopes, id: \.identity) { scope in
                        Label(scope.displayName ?? scope.identity, systemImage: "shippingbox")
                            .tag(scope.identity)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
