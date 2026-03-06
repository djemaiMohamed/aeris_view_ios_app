import SwiftUI
import SwiftData
import UserNotifications
import CoreBluetooth

struct SettingsView: View {
    @ObservedObject var bleManager: BLEManager
    @Environment(\.modelContext) private var modelContext
    @State private var userSettings: [UserSettings] = []
    @State private var showingMeasurementIntervalPicker = false
    @State private var showingTemperatureUnitPicker = false
    @State private var showingCO2ThresholdSlider = false
    @FocusState private var ppmFieldFocused: Bool
    @State private var didEnsureSettings = false
    
    private var currentSettings: UserSettings {
        userSettings.first ?? UserSettings()
    }

    private func loadUserSettings() {
        let descriptor = FetchDescriptor<UserSettings>()
        if let results = try? modelContext.fetch(descriptor) {
            userSettings = results
        }
    }

    private func ensureSettings() {
        guard !didEnsureSettings else { return }
        didEnsureSettings = true
        if userSettings.isEmpty {
            let newSettings = UserSettings()
            modelContext.insert(newSettings)
            try? modelContext.save()
            userSettings = [newSettings]
        }
    }
    
    var body: some View {
        NavigationView {
            List {
                // Show which device settings apply to when multiple devices connected
                if bleManager.connectedPeripherals.count > 1,
                   let active = bleManager.activePeripheral {
                    Section {
                        HStack {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundColor(.blue)
                            Text("Settings for: **\(bleManager.displayName(for: active))**")
                                .font(.subheadline)
                        }
                    }
                }

                DeviceSettingsSectionView(bleManager: bleManager, settings: currentSettings)
                CalibrationSectionView(bleManager: bleManager, ppmFieldFocused: $ppmFieldFocused)
                NotificationsSectionView(settings: currentSettings)
                DeviceManagementSectionView(bleManager: bleManager)
                DataManagementSectionView()
                AboutSectionView()
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            // Allow dismissing the keyboard by scrolling the list
            .scrollDismissesKeyboard(.interactively)
            // Single keyboard toolbar for the whole screen
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        if bleManager.connectedPeripherals.isEmpty {
                            Text("No devices connected")
                        } else {
                            ForEach(bleManager.connectedPeripherals, id: \.identifier) { p in
                                Button(action: { bleManager.setActivePeripheral(p) }) {
                                    Label(bleManager.displayName(for: p), systemImage: bleManager.activePeripheral?.identifier == p.identifier ? "checkmark.circle.fill" : "circle")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "dot.radiowaves.left.and.right")
                            Text("Devices")
                        }
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    if ppmFieldFocused {
                        Spacer()
                        Button("Done") { ppmFieldFocused = false }
                    }
                }
            }
            .task {
                loadUserSettings()
                ensureSettings()
            }
        }
    }
    
    // Section-specific helpers moved into subviews
}

// MARK: - Section Subviews

private struct DeviceSettingsSectionView: View {
    @ObservedObject var bleManager: BLEManager
    var settings: UserSettings
    
    var body: some View {
        Section("Device Settings") {
            NavigationLink {
                MeasurementIntervalView(
                    settings: settings,
                    onIntervalChanged: { newInterval in
                        bleManager.writeMeasurementInterval(newInterval)
                    }
                )
            } label: {
                SettingsRow(
                    icon: "clock.fill",
                    title: "Measurement Interval",
                    value: formatMeasurementInterval(settings.measurementInterval),
                    color: .blue
                )
            }
            
            NavigationLink {
                TemperatureUnitView(
                    settings: settings,
                    onUnitChanged: { newUnit in
                        bleManager.writeTemperatureUnit(newUnit == .celsius)
                    }
                )
            } label: {
                SettingsRow(
                    icon: "thermometer",
                    title: "Temperature Unit",
                    value: settings.temperatureUnit.rawValue,
                    color: .orange
                )
            }
            
            NavigationLink {
                CO2ThresholdView(settings: settings)
            } label: {
                SettingsRow(
                    icon: "exclamationmark.triangle.fill",
                    title: "CO2 Alert Threshold",
                    value: "\(Int(settings.co2AlertThreshold)) PPM",
                    color: .red
                )
            }
        }
    }

    private func formatMeasurementInterval(_ seconds: Int) -> String {
        if seconds < 3600 {
            let minutes = max(1, seconds / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        } else {
            let hours = seconds / 3600
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
    }
}

private struct CalibrationSectionView: View {
    @ObservedObject var bleManager: BLEManager
    @State private var ppmText: String = "400"
    @State private var showWarning: Bool = false
    @State private var showFinished: Bool = false
    var ppmFieldFocused: FocusState<Bool>.Binding
    
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "aqi.medium")
                        .foregroundColor(.orange)
                        .frame(width: 24)
                    Text("CO₂ Reference (PPM)")
                        .foregroundColor(.primary)
                    Spacer()
                    TextField("400", text: $ppmText)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(minWidth: 80)
                        .focused(ppmFieldFocused)
                        .submitLabel(.done)
                        .onSubmit { ppmFieldFocused.wrappedValue = false }
                        .onChange(of: ppmText) { newValue in
                            let filtered = newValue.filter { $0.isNumber }
                            if filtered != newValue { ppmText = filtered }
                        }
                }
                Text("Default is 400 PPM (fresh outdoor air). Adjust if you have a more accurate reference.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            Button(action: {
                if ppmText.isEmpty { ppmText = "400" }
                showWarning = true
            }) {
                HStack(spacing: 8) {
                    if bleManager.calibrationInProgress { ProgressView() }
                    Text(bleManager.calibrationInProgress ? "Calibrating…" : "Start Calibration")
                }
            }
            .disabled(bleManager.connectedPeripheral == nil || bleManager.calibrationInProgress)

            if !bleManager.calibrationStatusMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: bleManager.calibrationFinished ? "checkmark.circle.fill" : (bleManager.calibrationInProgress ? "hourglass" : "info.circle"))
                        .foregroundColor(bleManager.calibrationFinished ? .green : (bleManager.calibrationInProgress ? .orange : .secondary))
                    Text(bleManager.calibrationStatusMessage)
                        .font(.subheadline)
                        .foregroundColor(bleManager.calibrationFinished ? .green : .secondary)
                }
            }
        } header: {
            Text("Calibration")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                    Text("Place the device outdoors in fresh air before starting. Using an incorrect reference may degrade accuracy.")
                }
                Text("Tip: 400 PPM is typical outdoors. If possible, use a verified value from a high-accuracy instrument.")
                    .foregroundColor(.secondary)
            }
            .font(.footnote)
        }
        .alert("Important: Outdoor Calibration", isPresented: $showWarning) {
            Button("Cancel", role: .cancel) {}
            Button("I Understand") {
                let ppm = Int(ppmText) ?? 400
                let clamped = max(300, min(ppm, 5000))
                ppmText = String(clamped)
                bleManager.startCO2Calibration(ppm: clamped)
            }
        } message: {
            Text("Ensure the device is outdoors in fresh air. Calibration takes about 3 minutes. For best results, use an accurate reference value if available.")
        }
        .onChange(of: bleManager.calibrationFinished) { finished in
            if finished { showFinished = true }
        }
        .alert("Calibration Complete", isPresented: $showFinished) {
            Button("OK", role: .cancel) {
                // Clear the flag so the alert doesn't reappear on device switch
                bleManager.clearCalibrationFinished()
            }
        } message: {
            Text("The device reported calibration finished successfully.")
        }
    }

}

private struct NotificationsSectionView: View {
    @Environment(\.modelContext) private var modelContext
    var settings: UserSettings
    
    var body: some View {
        Section("Notifications") {
            Toggle(isOn: Binding(
                get: { settings.notificationsEnabled },
                set: { newValue in
                    settings.notificationsEnabled = newValue
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
        }
    }
}

private struct DeviceManagementSectionView: View {
    @ObservedObject var bleManager: BLEManager
    @State private var showRenameAlert = false
    @State private var renameText = ""
    
    var body: some View {
        Section("Device Management") {
            if bleManager.isBonded {
                // Rename device
                if let active = bleManager.activePeripheral {
                    Button {
                        renameText = bleManager.displayName(for: active)
                        showRenameAlert = true
                    } label: {
                        SettingsRow(
                            icon: "pencil.line",
                            title: "Rename Device",
                            value: bleManager.displayName(for: active),
                            color: .blue
                        )
                    }
                }
                
                SettingsRow(
                    icon: batteryIcon(for: bleManager.batteryLevel),
                    title: "Battery Level",
                    value: "\(bleManager.batteryLevel)%",
                    color: batteryColor(for: bleManager.batteryLevel)
                )
                
                Button {
                    bleManager.forgetBondedDevice()
                } label: {
                    SettingsRow(
                        icon: "wifi.slash",
                        title: "Forget This Device",
                        value: bleManager.activePeripheral.map { bleManager.displayName(for: $0) } ?? "N/A",
                        color: .red
                    )
                }
            } else {
                Text("No device bonded.")
                    .foregroundColor(.secondary)
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
        .alert("Rename Device", isPresented: $showRenameAlert) {
            TextField("Device name", text: $renameText)
            Button("Save") {
                if let active = bleManager.activePeripheral {
                    bleManager.renameDevice(active, to: renameText)
                }
            }
            Button("Reset to Default", role: .destructive) {
                if let active = bleManager.activePeripheral {
                    bleManager.renameDevice(active, to: nil)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a custom name for this device (e.g. Living Room, Bedroom)")
        }
    }
    
    private func batteryColor(for level: Int) -> Color {
        switch level {
        case 76...100: return .green
        case 51...75: return .yellow
        case 26...50: return .orange
        case 1...25: return .red
        default: return .gray
        }
    }
    
    private func batteryIcon(for level: Int) -> String {
        switch level {
        case 76...100: return "battery.100"
        case 51...75: return "battery.75"
        case 26...50: return "battery.25"
        case 1...25: return "battery.0"
        default: return "battery.0"
        }
    }
}

private struct DataManagementSectionView: View {
    @Environment(\.modelContext) private var modelContext
    
    var body: some View {
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

private struct AboutSectionView: View {
    var body: some View {
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
    let onIntervalChanged: ((Int) -> Void)?
    
    private let intervals = [60, 120, 300, 600, 1200, 1800, 3600] // seconds
    
    var body: some View {
        List {
            ForEach(intervals, id: \.self) { interval in
                Button {
                    settings.measurementInterval = interval
                    try? modelContext.save()
                    onIntervalChanged?(interval)
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
        if seconds < 3600 {
            let minutes = max(1, seconds / 60)
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        } else {
            let hours = seconds / 3600
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
    }
}

struct TemperatureUnitView: View {
    @ObservedObject var settings: UserSettings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    let onUnitChanged: ((TemperatureUnit) -> Void)?
    
    var body: some View {
        List {
            ForEach(TemperatureUnit.allCases, id: \.self) { unit in
                Button {
                    settings.temperatureUnit = unit
                    try? modelContext.save()
                    onUnitChanged?(unit)
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
    @State private var readings: [SensorReading] = []
    @State private var showingShareSheet = false
    @State private var exportURL: URL?

    private func loadReadings() {
        let descriptor = FetchDescriptor<SensorReading>()
        if let results = try? modelContext.fetch(descriptor) {
            readings = results
        }
    }
    
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
        .task { loadReadings() }
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
