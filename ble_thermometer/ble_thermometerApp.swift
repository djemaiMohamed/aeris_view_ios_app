//
//  ble_thermometerApp.swift
//  ble_thermometer
//
//  Created by Mohamed Djemai on 2025-03-30.
//

import SwiftUI
import SwiftData

@main
struct ble_thermometerApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            SensorReading.self,
            UserSettings.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
    }
}
