import SwiftUI
import Charts

struct HomeView: View {
    @ObservedObject var bleManager: BLEManager
    @State private var selectedTimeRange: TimeRange = .hour
    @State private var showingDeviceInfo = false
    @State private var showingAddDevice = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Connection Status Card
                    ConnectionStatusCard(bleManager: bleManager)
                    
                    // Air Quality Overview Card
                    AirQualityOverviewCard(bleManager: bleManager)
                    
                    // Sensor Readings Cards
                    SensorReadingsGrid(bleManager: bleManager)
                    
                    // Quick Insights Card
                    QuickInsightsCard(bleManager: bleManager)
                    
                    Spacer(minLength: 100)
                }
                .padding()
            }
            .navigationTitle(bleManager.activeDeviceDisplayName())
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingDeviceInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAddDevice = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Device")
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        if bleManager.connectedPeripherals.isEmpty {
                            Text("No devices connected")
                        } else {
                            ForEach(bleManager.connectedPeripherals, id: \.identifier) { p in
                                Button(action: { bleManager.setActivePeripheral(p) }) {
                                    Label(p.name ?? "Unknown", systemImage: bleManager.activePeripheral?.identifier == p.identifier ? "checkmark.circle.fill" : "circle")
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
            }
            .sheet(isPresented: $showingDeviceInfo) {
                DeviceInfoView(bleManager: bleManager)
            }
            .sheet(isPresented: $showingAddDevice) {
                DevicePairingView(bleManager: bleManager, autoStartScan: true)
            }
        }
    }
}

struct ConnectionStatusCard: View {
    @ObservedObject var bleManager: BLEManager
    
    var body: some View {
        HStack {
            Image(systemName: bleManager.connectedPeripheral != nil ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title2)
                .foregroundColor(bleManager.connectedPeripheral != nil ? .green : .orange)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(bleManager.connectionStatus)
                    .font(.headline)
                
                if let peripheral = bleManager.connectedPeripheral {
                    Text(peripheral.name ?? "Unknown Device")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Tap to reconnect")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            if bleManager.isConnecting {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .onTapGesture {
            if bleManager.connectedPeripheral == nil && !bleManager.peripherals.isEmpty {
                bleManager.connect(peripheral: bleManager.peripherals.first!)
            }
        }
    }
}

struct AirQualityOverviewCard: View {
    @ObservedObject var bleManager: BLEManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: bleManager.airQualityLevel.iconName)
                    .font(.title2)
                    .foregroundColor(bleManager.airQualityLevel.color)
                
                Text("Air Quality")
                    .font(.headline)
                
                Spacer()
                
                Text(bleManager.airQualityLevel.rawValue)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(bleManager.airQualityLevel.color.opacity(0.2))
                    .foregroundColor(bleManager.airQualityLevel.color)
                    .cornerRadius(8)
            }
            
            Text(getAirQualityRecommendation(level: bleManager.airQualityLevel, co2Value: bleManager.co2Value))
                .font(.body)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

struct SensorReadingsGrid: View {
    @ObservedObject var bleManager: BLEManager
    
    var body: some View {
        VStack(spacing: 16) {
            // Full-width CO2 card
            SensorCard(
                title: "CO2",
                value: formatCO2(bleManager.co2Value),
                icon: "aqi.medium",
                color: bleManager.airQualityLevel.color
            )
            
            // Temperature and Humidity cards in a row
            HStack(spacing: 16) {
                SensorCard(
                    title: "Temperature",
                    value: formatTemperature(bleManager.displayTemperature, isCelsius: bleManager.displayTemperatureUnit == .celsius),
                    icon: "thermometer",
                    color: .orange
                )
                
                SensorCard(
                    title: "Humidity",
                    value: formatHumidity(bleManager.humValue),
                    icon: "humidity",
                    color: .blue
                )
            }
        }
    }
}

struct SensorCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var isCO2Card: Bool { title == "CO2" }
    
    var body: some View {
        VStack(alignment: .leading, spacing: isCO2Card ? 12 : 8) {
            HStack {
                Image(systemName: icon)
                    .font(isCO2Card ? .title2 : .title3)
                    .foregroundColor(color)
                
                Spacer()
            }
            
            Text(value)
                .font(isCO2Card ? .largeTitle : .title2)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(isCO2Card ? 24 : 16)
        .background {
            if isCO2Card {
                LinearGradient(
                    gradient: Gradient(colors: [color.opacity(0.1), color.opacity(0.05)]), 
                    startPoint: .topLeading, 
                    endPoint: .bottomTrailing
                )
            } else {
                Color(.systemGray6)
            }
        }
        .cornerRadius(isCO2Card ? 16 : 12)
        .shadow(color: isCO2Card ? color.opacity(0.3) : .clear, radius: isCO2Card ? 8 : 0, x: 0, y: 4)
    }
}

struct QuickInsightsCard: View {
    @ObservedObject var bleManager: BLEManager
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Insights")
                .font(.headline)
            
            VStack(spacing: 8) {
                InsightRow(
                    icon: "leaf.fill",
                    text: bleManager.airQualityLevel.rawValue == "Waiting for Data" ? "Waiting for sensor data..." : "Air quality is \(bleManager.airQualityLevel.rawValue.lowercased())",
                    color: bleManager.airQualityLevel.color
                )
                
                InsightRow(
                    icon: "thermometer",
                    text: getTemperatureInsight(temp: bleManager.tempValue),
                    color: .orange
                )
                
                InsightRow(
                    icon: "drop.fill",
                    text: getHumidityInsight(humidity: bleManager.humValue),
                    color: .blue
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

struct InsightRow: View {
    let icon: String
    let text: String
    let color: Color
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            
            Text(text)
                .font(.body)
                .foregroundColor(.primary)
            
            Spacer()
        }
    }
}

// Helper functions
private func formatLastUpdate(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

private func getTemperatureInsight(temp: Double) -> String {
    // Check if temperature is 0 (no data received yet)
    guard temp != 0 else { return "Waiting for temperature data..." }
    
    switch temp {
    case ..<18:
        return "Temperature is quite cool"
    case 18..<22:
        return "Temperature is comfortable"
    case 22..<26:
        return "Temperature is warm"
    default:
        return "Temperature is hot"
    }
}

private func getHumidityInsight(humidity: Double) -> String {
    // Check if humidity is 0 (no data received yet)
    guard humidity != 0 else { return "Waiting for humidity data..." }
    
    switch humidity {
    case ..<30:
        return "Air is quite dry"
    case 30..<60:
        return "Humidity is comfortable"
    case 60..<70:
        return "Air is humid"
    default:
        return "Air is very humid"
    }
}

enum TimeRange: String, CaseIterable {
    case hour = "1H"
    case day = "1D"
    case week = "1W"
    case month = "1M"
}

#Preview {
    HomeView(bleManager: BLEManager())
}
