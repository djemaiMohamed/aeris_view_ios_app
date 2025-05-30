import SwiftUI
import SwiftData
import CoreBluetooth

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var bleManager = BLEManager()
    @Query private var userSettings: [UserSettings]
    @State private var showOnboarding = false
    @State private var selectedTab = 0
    
    var currentSettings: UserSettings {
        userSettings.first ?? UserSettings()
    }
    
    var body: some View {
        Group {
            //bleManager.reconnectToBondedDevice(with: bleManager.centralManager)
            if !bleManager.isBonded && !bleManager.isBluetoothEnabled {
                OnboardingView(bleManager: bleManager)
            } else if !bleManager.isBonded {
                DevicePairingView(bleManager: bleManager)
            } else {
                TabView(selection: $selectedTab) {
                    HomeView(bleManager: bleManager)
                        .tabItem {
                            Image(systemName: "house.fill")
                            Text("Home")
                        }
                        .tag(0)
                    
                    HistoryView()
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
                            Text("Account")
                        }
                        .tag(3)
                }
                .accentColor(.blue)
            }
        }
        .onAppear {
            bleManager.setModelContext(modelContext)            
            // Create default settings if none exist
            if userSettings.isEmpty {
                let defaultSettings = UserSettings()
                modelContext.insert(defaultSettings)
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
            }
        }
    }
}
