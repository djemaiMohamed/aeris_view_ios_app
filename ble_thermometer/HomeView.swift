import SwiftUI
import Charts

struct HomeView: View {
    @ObservedObject var bleManager: BLEManager
    @State private var selectedTimeRange: TimeRange = .hour
    @State private var showingDeviceInfo = false
    
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
            .navigationTitle("Air Quality")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingDeviceInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $showingDeviceInfo) {
                DeviceInfoView(bleManager: bleManager)
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
            
            Text(getAirQualityRecommendation(level: bleManager.airQualityLevel))
                .font(.body)
                .foregroundColor(.secondary)
            
            HStack {
                Text("Last updated:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(formatLastUpdate(bleManager.lastUpdateTime))
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Spacer()
            }
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
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 16) {
            SensorCard(
                title: "CO2",
                value: formatCO2(bleManager.co2Value),
                icon: "aqi.medium",
                color: bleManager.airQualityLevel.color
            )
            
            SensorCard(
                title: "Temperature",
                value: formatTemperature(bleManager.tempValue, isCelsius: bleManager.isTempCelsius),
                icon: "thermometer",
                color: .orange
            )
            
            SensorCard(
                title: "Humidity",
                value: formatHumidity(bleManager.humValue),
                icon: "humidity",
                color: .blue
            )
            
            SensorCard(
                title: "Status",
                value: bleManager.isBonded ? "Bonded" : "Not Bonded",
                icon: bleManager.isBonded ? "link" : "link.badge.plus",
                color: bleManager.isBonded ? .green : .gray
            )
        }
    }
}

struct SensorCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundColor(color)
                
                Spacer()
            }
            
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
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
                    text: "Air quality is \(bleManager.airQualityLevel.rawValue.lowercased())",
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
