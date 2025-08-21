import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SensorReading.timestamp, order: .reverse) private var readings: [SensorReading]
    @Query private var userSettings: [UserSettings]
    @ObservedObject var bleManager: BLEManager
    @State private var selectedTimeRange: HistoryTimeRange = .day
    @State private var selectedMetric: SensorMetric = .co2
    
    private var currentSettings: UserSettings {
        userSettings.first ?? UserSettings()
    }
    
    var filteredReadings: [SensorReading] {
        let now = Date()
        let cutoffDate: Date
        
        switch selectedTimeRange {
        case .hour:
            cutoffDate = Calendar.current.date(byAdding: .hour, value: -1, to: now) ?? now
        case .day:
            cutoffDate = Calendar.current.date(byAdding: .day, value: -1, to: now) ?? now
        case .week:
            cutoffDate = Calendar.current.date(byAdding: .weekOfYear, value: -1, to: now) ?? now
        case .month:
            cutoffDate = Calendar.current.date(byAdding: .month, value: -1, to: now) ?? now
        }
        
        let timeFiltered = readings.filter { $0.timestamp >= cutoffDate }
        if let activeId = bleManager.activePeripheral?.identifier.uuidString {
            return timeFiltered.filter { $0.deviceId == activeId }
        }
        return timeFiltered
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Time Range Picker
                Picker("Time Range", selection: $selectedTimeRange) {
                    ForEach(HistoryTimeRange.allCases, id: \.self) { range in
                        Text(range.displayName).tag(range)
                    }
                }
                .pickerStyle(SegmentedPickerStyle())
                .padding()
                
                if filteredReadings.isEmpty {
                    // Empty State
                    VStack(spacing: 20) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.system(size: 60))
                            .foregroundColor(.gray)
                        
                        Text("No Data Available")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text("Start monitoring to see your air quality history")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            // Metric Selector
                            MetricSelectorCard(selectedMetric: $selectedMetric)
                            
                            // Chart Card
                            ChartCard(readings: filteredReadings, metric: selectedMetric, userSettings: currentSettings)
                            
                            // Statistics Card
                            StatisticsCard(readings: filteredReadings, metric: selectedMetric, userSettings: currentSettings)
                            
                            // Recent Readings List
                            RecentReadingsCard(readings: Array(filteredReadings.prefix(10)), userSettings: currentSettings)
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
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
        }
    }
}

struct MetricSelectorCard: View {
    @Binding var selectedMetric: SensorMetric
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Metric")
                .font(.headline)
            
            HStack(spacing: 12) {
                ForEach(SensorMetric.allCases, id: \.self) { metric in
                    Button {
                        selectedMetric = metric
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: metric.iconName)
                                .font(.title3)
                            Text(metric.displayName)
                                .font(.caption)
                        }
                        .foregroundColor(selectedMetric == metric ? .white : metric.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(selectedMetric == metric ? metric.color : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(metric.color, lineWidth: 1)
                        )
                        .cornerRadius(8)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

struct ChartCard: View {
    let readings: [SensorReading]
    let metric: SensorMetric
    let userSettings: UserSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: metric.iconName)
                    .foregroundColor(metric.color)
                Text("\(metric.displayName) Over Time")
                    .font(.headline)
                Spacer()
            }
            
            Chart(readings) { reading in
                let value = metric.getValue(from: reading, userSettings: userSettings)
                if value > 0 {
                    // Area fill with gradient
                    AreaMark(
                        x: .value("Time", reading.timestamp),
                        y: .value(metric.displayName, value)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                metric.color.opacity(0.3),
                                metric.color.opacity(0.1),
                                metric.color.opacity(0.05)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)
                    
                    // Main line
                    LineMark(
                        x: .value("Time", reading.timestamp),
                        y: .value(metric.displayName, value)
                    )
                    .foregroundStyle(metric.color)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                    
                    // Data points
                    PointMark(
                        x: .value("Time", reading.timestamp),
                        y: .value(metric.displayName, value)
                    )
                    .foregroundStyle(metric.color)
                    .symbolSize(40)
                    .opacity(0.8)
                }
            }
            .frame(height: 250)
            .chartYAxisLabel(metric.unit)
            .chartXAxisLabel("Time")
            .chartPlotStyle { plotArea in
                plotArea
                    .background(
                        LinearGradient(
                            gradient: Gradient(colors: [
                                Color(.systemBackground),
                                metric.color.opacity(0.02)
                            ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .border(metric.color.opacity(0.1), width: 1)
            }
            .animation(.easeInOut(duration: 1.2), value: readings.count)
            .animation(.easeInOut(duration: 0.8), value: metric)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

struct StatisticsCard: View {
    let readings: [SensorReading]
    let metric: SensorMetric
    let userSettings: UserSettings
    
    private var statistics: (min: Double, max: Double, avg: Double) {
        let values = readings.map { metric.getValue(from: $0, userSettings: userSettings) }
        guard !values.isEmpty else { return (0, 0, 0) }
        
        return (
            min: values.min() ?? 0,
            max: values.max() ?? 0,
            avg: values.reduce(0, +) / Double(values.count)
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Statistics")
                .font(.headline)
            
            HStack(spacing: 16) {
                StatisticItem(
                    title: "Min",
                    value: metric.formatValue(statistics.min, userSettings: userSettings),
                    color: .blue
                )
                
                StatisticItem(
                    title: "Average",
                    value: metric.formatValue(statistics.avg, userSettings: userSettings),
                    color: .green
                )
                
                StatisticItem(
                    title: "Max",
                    value: metric.formatValue(statistics.max, userSettings: userSettings),
                    color: .red
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

struct StatisticItem: View {
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            
            Text(value)
                .font(.headline)
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

struct RecentReadingsCard: View {
    let readings: [SensorReading]
    let userSettings: UserSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recent Readings")
                .font(.headline)
            
            LazyVStack(spacing: 8) {
                ForEach(readings) { reading in
                    ReadingRow(reading: reading, userSettings: userSettings)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}

struct ReadingRow: View {
    let reading: SensorReading
    let userSettings: UserSettings
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(formatTime(reading.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                Text(formatDate(reading.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            HStack(spacing: 12) {
                MetricBadge(
                    value: formatCO2(reading.co2Value),
                    color: getAirQualityLevel(co2: reading.co2Value).color
                )
                
                MetricBadge(
                    value: formatTemperatureForUser(reading.temperature, reading.isCelsius, userUnit: userSettings.temperatureUnit),
                    color: .orange
                )
                
                MetricBadge(
                    value: formatHumidity(reading.humidity),
                    color: .blue
                )
            }
        }
        .padding(.vertical, 4)
    }
}

struct MetricBadge: View {
    let value: String
    let color: Color
    
    var body: some View {
        Text(value)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }
}

// Helper types and functions
enum HistoryTimeRange: CaseIterable {
    case hour, day, week, month
    
    var displayName: String {
        switch self {
        case .hour: return "1H"
        case .day: return "1D"
        case .week: return "1W"
        case .month: return "1M"
        }
    }
}

enum SensorMetric: CaseIterable {
    case co2, temperature, humidity
    
    var displayName: String {
        switch self {
        case .co2: return "CO2"
        case .temperature: return "Temperature"
        case .humidity: return "Humidity"
        }
    }
    
    var iconName: String {
        switch self {
        case .co2: return "aqi.medium"
        case .temperature: return "thermometer"
        case .humidity: return "humidity"
        }
    }
    
    var color: Color {
        switch self {
        case .co2: return .green
        case .temperature: return .orange
        case .humidity: return .blue
        }
    }
    
    var unit: String {
        switch self {
        case .co2: return "PPM"
        case .temperature: return "°"
        case .humidity: return "%"
        }
    }
    
    func getValue(from reading: SensorReading, userSettings: UserSettings? = nil) -> Double {
        switch self {
        case .co2: return reading.co2Value
        case .temperature:
            guard let settings = userSettings else { return reading.temperature }
            let convertedTemp: Double
            if settings.temperatureUnit == .celsius {
                convertedTemp = reading.isCelsius ? reading.temperature : convertTemperature(reading.temperature, toCelsius: true)
            } else {
                convertedTemp = reading.isCelsius ? convertTemperature(reading.temperature, toCelsius: false) : reading.temperature
            }
            // Filter out 32°F (0°C) values
            if abs(convertedTemp - (settings.temperatureUnit == .celsius ? 0.0 : 32.0)) < 0.1 {
                return 0
            }
            return convertedTemp
        case .humidity: return reading.humidity
        }
    }
    
    func formatValue(_ value: Double, userSettings: UserSettings? = nil) -> String {
        switch self {
        case .co2: return formatCO2(value)
        case .temperature:
            guard let settings = userSettings else { return String(format: "%.1f°", value) }
            return formatTemperature(value, isCelsius: settings.temperatureUnit == .celsius)
        case .humidity: return formatHumidity(value)
        }
    }
}

private func formatTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter.string(from: date)
}

private func formatDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    return formatter.string(from: date)
}

private func formatTemperatureForUser(_ temp: Double, _ isCelsius: Bool, userUnit: TemperatureUnit) -> String {
    let convertedTemp: Double
    let displayUnit: Bool
    
    if userUnit == .celsius {
        convertedTemp = isCelsius ? temp : convertTemperature(temp, toCelsius: true)
        displayUnit = true
    } else {
        convertedTemp = isCelsius ? convertTemperature(temp, toCelsius: false) : temp
        displayUnit = false
    }
    
    return formatTemperature(convertedTemp, isCelsius: displayUnit)
}

#Preview {
    HistoryView(bleManager: BLEManager())
        .modelContainer(for: [SensorReading.self])
}
