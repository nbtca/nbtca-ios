import SwiftUI

struct ContentView: View {
    @State private var settings = AppSettings.shared
    @State private var auth = AuthStore.shared
    var body: some View {
        TabView {
            Tab("拔电关机", systemImage: "newspaper") { NavigationStack { NewsroomView() } }
            Tab("维修", systemImage: "wrench.and.screwdriver") { NavigationStack { RepairHomeView() } }
            Tab("工具", systemImage: "square.grid.2x2") { NavigationStack { ToolsView() } }
            Tab("个人中心", systemImage: "person.crop.circle") { NavigationStack { ProfileView() } }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tint(.brand).preferredColorScheme(settings.colorScheme)
        .environment(\.locale, Locale(identifier: "zh_CN"))
        .task { await auth.restore() }
    }
}

#Preview { ContentView() }
