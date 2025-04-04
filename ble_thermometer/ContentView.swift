import SwiftUI
import CoreBluetooth

struct ContentView: View {
    @State private var selectedTab: Int = 0
    @ObservedObject var bleManager = BLEManager() // Create a single instance

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView(bleManager: bleManager, selectedTab: $selectedTab) // Pass the instance
                .tabItem {
                    Label("Home", systemImage: "house")
                }
                .tag(0)
            SettingsView(bleManager: bleManager) // Pass the same instance
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
                .tag(1)
            ProfileView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
                .tag(2)
        }
    }
}
