import SwiftUI
import SwiftData
import CoreBluetooth

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("demoModeEnabled") private var demoModeEnabled = false
    @StateObject private var bleManager = BLEManager()
    @State private var userSettings: [UserSettings] = []
    @State private var showOnboarding = false
    @State private var selectedTab = 0
    
    var currentSettings: UserSettings {
        userSettings.first ?? UserSettings()
    }

    private func loadUserSettings() {
        let descriptor = FetchDescriptor<UserSettings>()
        if let results = try? modelContext.fetch(descriptor) {
            userSettings = results
        }
    }
    
    var body: some View {
        Group {
            //bleManager.reconnectToBondedDevice(with: bleManager.centralManager)
            if demoModeEnabled || bleManager.isBonded {
                TabView(selection: $selectedTab) {
                    HomeView(bleManager: bleManager)
                        .tabItem {
                            Image(systemName: "house.fill")
                            Text("Home")
                        }
                        .tag(0)
                    
                    HistoryView(bleManager: bleManager)
                        .tabItem {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                            Text("History")
                        }
                        .tag(1)
                    
                    SettingsView(bleManager: bleManager)
                        .tabItem {
                            Image(systemName: "gearshape.fill")
                            Text("Settings")
                        }
                        .tag(2)
                    
                    AccountView()
                        .tabItem {
                            Image(systemName: "person.fill")
                            Text("Info")
                        }
                        .tag(3)
                }
                .accentColor(.blue)
            } else if !bleManager.isBluetoothEnabled {
                OnboardingView(
                    bleManager: bleManager,
                    onEnableDemoMode: {
                        demoModeEnabled = true
                    }
                )
            } else {
                DevicePairingView(
                    bleManager: bleManager,
                    onEnableDemoMode: {
                        demoModeEnabled = true
                    }
                )
            }
        }
        .onAppear {
            loadUserSettings()
            bleManager.setModelContext(modelContext)            
            // Create default settings if none exist
            if userSettings.isEmpty {
                let defaultSettings = UserSettings()
                modelContext.insert(defaultSettings)
                userSettings = [defaultSettings]
                bleManager.setUserSettings(defaultSettings)
            } else {
                // Pass UserSettings reference to BLEManager
                if let settings = userSettings.first {
                    bleManager.setUserSettings(settings)
                }
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                // Perform memory cleanup when app goes to background
                bleManager.performMemoryCleanup()
            } else if newPhase == .active {
                bleManager.attemptReconnectIfNeeded()
            }
        }
    }
}
