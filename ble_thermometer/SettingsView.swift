import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @ObservedObject var bleManager: BLEManager
    @Environment(\.modelContext) private var modelContext
    @Query private var userSettings: [UserSettings]
    @State private var showingMeasurementIntervalPicker = false
    @State private var showingTemperatureUnitPicker = false
    @State private var showingCO2ThresholdSlider = false
    
    private var currentSettings: UserSettings {
        if let settings = userSettings.first {
            return settings
        } else {
            let newSettings = UserSettings()
            modelContext.insert(newSettings)
            return newSettings
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                // Device Settings Section
                Section("Device Settings") {
                    NavigationLink {
                        MeasurementIntervalView(settings: currentSettings)
                    } label: {
                        SettingsRow(
                            icon: "clock.fill",
                            title: "Measurement Interval",
                            value: "\(currentSettings.measurementInterval)s",
                            color: .blue
                        )
                    }
                    
                    NavigationLink {
                        TemperatureUnitView(settings: currentSettings)
                    } label: {
                        SettingsRow(
                            icon: "thermometer",
                            title: "Temperature Unit",
                            value: currentSettings.temperatureUnit.rawValue,
                            color: .orange
                        )
                    }
                    
                    NavigationLink {
                        CO2ThresholdView(settings: currentSettings)
                    } label: {
                        SettingsRow(
                            icon: "exclamationmark.triangle.fill",
                            title: "CO2 Alert Threshold",
                            value: "\(Int(currentSettings.co2AlertThreshold)) PPM",
                            color: .red
                        )
                    }
                }
                
                // Notifications Section
                Section("Notifications") {
                    Toggle(isOn: Binding(
                        get: { currentSettings.notificationsEnabled },
                        set: { newValue in
                            currentSettings.notificationsEnabled = newValue
                            try? modelContext.save()
                        }
                    )) {
                        SettingsRow(
                            icon: "bell.fill",
                            title: "Air Quality Alerts",
                            value: nil,
                            color: .purple
                        )
                    }
                    
                    if currentSettings.notificationsEnabled {
                        Button("Test Notification") {
                            testNotification()
                        }
                        .foregroundColor(.blue)
                    }
                }
                
                // Device Management Section
                Section("Device Management") {
                    if bleManager.connectedPeripheral != nil {
                        Button {
                            if let peripheral = bleManager.connectedPeripheral {
                                bleManager.disconnect(peripheral: peripheral)
                            }
                        } label: {
                            SettingsRow(
                                icon: "link.badge.plus",
                                title: "Disconnect Device",
                                value: nil,
                                color: .red
                            )
                        }
                    } else {
                        Button {
                            bleManager.startScan()
                        } label: {
                            SettingsRow(
                                icon: "magnifyingglass",
                                title: "Scan for Devices",
                                value: nil,
                                color: .blue
                            )
                        }
                    }
                    
                    NavigationLink {
                        DeviceInfoView(bleManager: bleManager)
                    } label: {
                        SettingsRow(
                            icon: "info.circle.fill",
                            title: "Device Information",
                            value: nil,
                            color: .gray
                        )
                    }
                }
                
                // Data Management Section
                Section("Data Management") {
                    NavigationLink {
                        DataExportView()
                    } label: {
                        SettingsRow(
                            icon: "square.and.arrow.up.fill",
                            title: "Export Data",
                            value: nil,
                            color: .green
                        )
                    }
                    
                    Button {
                        clearAllData()
                    } label: {
                        SettingsRow(
                            icon: "trash.fill",
                            title: "Clear All Data",
                            value: nil,
                            color: .red
                        )
                    }
                }
                
                // About Section
                Section("About") {
                    SettingsRow(
                        icon: "info.circle.fill",
                        title: "Version",
                        value: "1.0.0",
                        color: .gray
                    )
                    
                    SettingsRow(
                        icon: "person.fill",
                        title: "Developer",
                        value: "Mohamed Djemai",
                        color: .blue
                    )
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
        }
    }
    
    private func testNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Test Notification"
        content.body = "This is a test notification from Air Quality Monitor."
        content.sound = UNNotificationSound.default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error sending test notification: \(error)")
            }
        }
    }
    
    private func clearAllData() {
        do {
            try modelContext.delete(model: SensorReading.self)
            try modelContext.save()
        } catch {
            print("Error clearing data: \(error)")
        }
    }
}

struct SettingsRow: View {
    let icon: String
    let title: String
    let value: String?
    let color: Color
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            
            Text(title)
                .foregroundColor(.primary)
            
            Spacer()
            
            if let value = value {
                Text(value)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct MeasurementIntervalView: View {
    @ObservedObject var settings: UserSettings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    private let intervals = [10, 30, 60, 120, 300, 600] // seconds
    
    var body: some View {
        List {
            ForEach(intervals, id: \.self) { interval in
                Button {
                    settings.measurementInterval = interval
                    try? modelContext.save()
                    dismiss()
                } label: {
                    HStack {
                        Text(formatInterval(interval))
                            .foregroundColor(.primary)
                        
                        Spacer()
                        
                        if settings.measurementInterval == interval {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("Measurement Interval")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private func formatInterval(_ seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds) seconds"
        } else {
            let minutes = seconds / 60
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
    }
}

struct TemperatureUnitView: View {
    @ObservedObject var settings: UserSettings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        List {
            ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                Button {
                    settings.temperatureUnit = unit
                    try? modelContext.save()
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(unit.rawValue)
                                .foregroundColor(.primary)
                            Text(unit.symbol)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        Spacer()
                        
                        if settings.temperatureUnit == unit {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }
            }
        }
        .navigationTitle("Temperature Unit")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct CO2ThresholdView: View {
    @ObservedObject var settings: UserSettings
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("CO2 Alert Threshold")
                    .font(.headline)
                
                Text("\(Int(settings.co2AlertThreshold)) PPM")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .foregroundColor(getAirQualityLevel(co2: settings.co2AlertThreshold).color)
            }
            .padding()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Air Quality Levels")
                    .font(.headline)
                
                VStack(spacing: 8) {
                    ThresholdRow(range: "0-400 PPM", level: "Excellent", color: .green)
                    ThresholdRow(range: "400-1000 PPM", level: "Good", color: .mint)
                    ThresholdRow(range: "1000-2000 PPM", level: "Moderate", color: .yellow)
                    ThresholdRow(range: "2000-5000 PPM", level: "Poor", color: .orange)
                    ThresholdRow(range: "5000+ PPM", level: "Very Poor", color: .red)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            
            VStack(spacing: 8) {
                Text("Threshold: \(Int(settings.co2AlertThreshold)) PPM")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Slider(
                    value: Binding(
                        get: { settings.co2AlertThreshold },
                        set: { newValue in
                            settings.co2AlertThreshold = newValue
                            try? modelContext.save()
                        }
                    ),
                    in: 400...5000,
                    step: 100
                )
                .accentColor(getAirQualityLevel(co2: settings.co2AlertThreshold).color)
                
                HStack {
                    Text("400")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    Text("5000")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            
            Spacer()
        }
        .padding()
        .navigationTitle("CO2 Threshold")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct ThresholdRow: View {
    let range: String
    let level: String
    let color: Color
    
    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
            
            Text(range)
                .font(.body)
                .foregroundColor(.primary)
            
            Spacer()
            
            Text(level)
                .font(.body)
                .fontWeight(.medium)
                .foregroundColor(color)
        }
    }
}

struct DataExportView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var readings: [SensorReading]
    @State private var showingShareSheet = false
    @State private var exportURL: URL?
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 60))
                .foregroundColor(.blue)
            
            Text("Export Data")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Export your sensor readings as a CSV file")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            VStack(spacing: 12) {
                Text("Total Readings: \(readings.count)")
                    .font(.headline)
                
                if let firstReading = readings.last,
                   let lastReading = readings.first {
                    Text("From: \(formatDate(firstReading.timestamp))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Text("To: \(formatDate(lastReading.timestamp))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
            
            Button("Export CSV") {
                exportData()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(readings.isEmpty)
            
            Spacer()
        }
        .padding()
        .navigationTitle("Export Data")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingShareSheet) {
            if let url = exportURL {
                ShareSheet(urls: [url])
            }
        }
    }
    
    private func exportData() {
        let csvContent = generateCSV()
        
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let fileName = "air_quality_data_\(Date().timeIntervalSince1970).csv"
        let fileURL = documentsPath.appendingPathComponent(fileName)
        
        do {
            try csvContent.write(to: fileURL, atomically: true, encoding: .utf8)
            exportURL = fileURL
            showingShareSheet = true
        } catch {
            print("Error writing CSV file: \(error)")
        }
    }
    
    private func generateCSV() -> String {
        var csv = "Timestamp,CO2 (PPM),Temperature,Humidity (%),Temperature Unit\n"
        
        for reading in readings.reversed() {
            let timestamp = ISO8601DateFormatter().string(from: reading.timestamp)
            let tempUnit = reading.isCelsius ? "C" : "F"
            csv += "\(timestamp),\(reading.co2Value),\(reading.temperature),\(reading.humidity),\(tempUnit)\n"
        }
        
        return csv
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

import UserNotifications

#Preview {
    SettingsView(bleManager: BLEManager())
        .modelContainer(for: [UserSettings.self, SensorReading.self])
}
