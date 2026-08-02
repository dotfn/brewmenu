import SwiftUI

struct CategoryView: View {
    let category: PackageCategory
    let dashboardViewModel: DashboardViewModel

    private var packages: [InstalledPackage] {
        dashboardViewModel.packages(in: category).sorted { $0.name < $1.name }
    }

    var body: some View {
        let packages = packages
        Group {
            if packages.isEmpty {
                ContentUnavailableView(L("No packages in this category"), systemImage: category.systemImage)
            } else {
                List(packages) { pkg in
                    InstalledPackageRow(package: pkg, dashboardViewModel: dashboardViewModel)
                }
                .scrollContentBackground(.hidden)
            }
        }
        // A toolbar is for actions, not information — cramming the package count in
        // there as bare text fought the framework (uneven spacing, no real button
        // chrome to anchor it). `navigationSubtitle` is the native slot for exactly
        // this: secondary text under the title, no layout hacks required.
        .navigationSubtitle(packages.count == 1 ? L("1 package") : L("\(packages.count) packages"))
    }
}
