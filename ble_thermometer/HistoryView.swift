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
    
    // Cached filtered readings for performance
    @State private var cachedReadings: [SensorReading] = []
    @State private var lastCacheUpdate: Date = .distantPast
    @State private var isLoading: Bool = false
    
    private var currentSettings: UserSettings {
        userSettings.first ?? UserSettings()
    }
    
    // Optimized filtered readings with caching
    private func updateFilteredReadings() {
        isLoading = true
        
        DispatchQueue.global(qos: .userInitiated).async {
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
            
            var timeFiltered = readings.filter { $0.timestamp >= cutoffDate }
            if let activeId = bleManager.activePeripheral?.identifier.uuidString {
                timeFiltered = timeFiltered.filter { $0.deviceId == activeId }
            }
            
            // Downsample for large datasets (keep max ~200 points for performance)
            let maxPoints = 200
            let result: [SensorReading]
            if timeFiltered.count > maxPoints {
                let step = timeFiltered.count / maxPoints
                result = stride(from: 0, to: timeFiltered.count, by: step).map { timeFiltered[$0] }
            } else {
                result = timeFiltered
            }
            
            DispatchQueue.main.async {
                cachedReadings = result
                lastCacheUpdate = now
                isLoading = false
            }
        }
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
                .onChange(of: selectedTimeRange) { _, _ in
                    updateFilteredReadings()
                }
                
                if isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading data...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if cachedReadings.isEmpty {
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
                            ChartCard(
                                readings: cachedReadings,
                                metric: selectedMetric,
                                userSettings: currentSettings,
                                timeRange: selectedTimeRange
                            )
                            
                            // Statistics Card
                            StatisticsCard(readings: cachedReadings, metric: selectedMetric, userSettings: currentSettings)
                            
                            // Recent Readings List
                            RecentReadingsCard(readings: Array(cachedReadings.prefix(10)), userSettings: currentSettings)
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        bleManager.requestSyncData()
                    }) {
                        if bleManager.syncState.isSyncing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .disabled(bleManager.connectedPeripheral == nil || bleManager.syncState.isSyncing)
                }
            }
            .overlay(alignment: .bottom) {
                // Sync status overlay
                if case .syncing(_, let count) = bleManager.syncState {
                    SyncProgressBanner(receivedCount: count)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if case .completed(let total) = bleManager.syncState {
                    SyncCompletedBanner(totalReceived: total) {
                        bleManager.syncState = .idle
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: bleManager.syncState)
            .onAppear {
                updateFilteredReadings()
            }
            .onChange(of: readings.count) { _, _ in
                updateFilteredReadings()
            }
            .onChange(of: bleManager.activePeripheral?.identifier) { _, _ in
                updateFilteredReadings()
            }
        }
    }
}

struct MetricSelectorCard: View {
    @Binding var selectedMetric: SensorMetric
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Select Metric")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            
            HStack(spacing: 10) {
                ForEach(SensorMetric.allCases, id: \.self) { metric in
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedMetric = metric
                        }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: metric.iconName)
                                .font(.system(size: 20, weight: .medium))
                            Text(metric.displayName)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .foregroundColor(selectedMetric == metric ? .white : metric.color)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selectedMetric == metric ? metric.color : metric.color.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selectedMetric == metric ? Color.clear : metric.color.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
    }
}

struct ChartCard: View {
    let readings: [SensorReading]
    let metric: SensorMetric
    let userSettings: UserSettings
    let timeRange: HistoryTimeRange
    
    // Sorted readings for proper chart display
    private var sortedReadings: [SensorReading] {
        readings.sorted { $0.timestamp < $1.timestamp }
    }
    
    // Calculate dynamic chart width based on data points and time range
    private var chartWidth: CGFloat {
        let baseWidth: CGFloat = UIScreen.main.bounds.width - 100 // Account for Y-axis
        let pointWidth: CGFloat
        
        switch timeRange {
        case .hour: pointWidth = 40
        case .day: pointWidth = 30
        case .week: pointWidth = 20
        case .month: pointWidth = 15
        }
        
        let calculatedWidth = CGFloat(sortedReadings.count) * pointWidth
        return max(baseWidth, calculatedWidth)
    }
    
    // Check if chart needs to scroll
    private var needsScroll: Bool {
        chartWidth > UIScreen.main.bounds.width - 100
    }
    
    // Calculate Y-axis range for the metric
    private var yAxisRange: (min: Double, max: Double) {
        let values = sortedReadings.map { metric.getValue(from: $0, userSettings: userSettings) }.filter { $0 > 0 }
        guard !values.isEmpty else {
            return metric.defaultRange
        }
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 100
        // Add 10% padding
        let padding = (maxVal - minVal) * 0.1
        return (min: max(0, minVal - padding), max: maxVal + padding)
    }
    
    // Y-axis values for display
    private var yAxisValues: [Double] {
        let range = yAxisRange
        let step = (range.max - range.min) / 5
        
        // Guard against zero step (when min == max)
        guard step > 0 else {
            // Return a single value or create artificial range
            let value = range.min
            if value == 0 {
                return [0, 20, 40, 60, 80, 100]
            }
            // Create range around the single value (±20%)
            let padding = max(value * 0.2, 1)
            let artificialStep = (padding * 2) / 5
            return stride(from: value - padding, through: value + padding, by: artificialStep).map { $0 }
        }
        
        return stride(from: range.min, through: range.max, by: step).map { $0 }
    }
    
    // Y-axis unit label
    private var yAxisLabel: String {
        switch metric {
        case .co2: return "CO₂ (ppm)"
        case .temperature: 
            return userSettings.temperatureUnit == .celsius ? "Temp (°C)" : "Temp (°F)"
        case .humidity: return "Humidity (%)"
        }
    }
    
    // Number of X-axis marks based on time range
    private var xAxisMarkCount: Int {
        switch timeRange {
        case .hour: return 12   // Every 5 minutes
        case .day: return 24    // Every hour
        case .week: return 14   // Every 12 hours
        case .month: return 30  // Every day
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Image(systemName: metric.iconName)
                    .font(.title3)
                    .foregroundColor(metric.color)
                
                Text("\(metric.displayName) Over Time")
                    .font(.headline)
                
                Spacer()
                
                // Data point count badge
                Text("\(sortedReadings.count) points")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
            }
            
            // Chart with sticky Y-axis
            HStack(alignment: .top, spacing: 0) {
                // Fixed Y-axis on the left
                VStack(alignment: .trailing, spacing: 0) {
                    // Y-axis label
                    Text(yAxisLabel)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(height: 16)
                    
                    // Y-axis values
                    GeometryReader { geometry in
                        let height = geometry.size.height
                        let stepHeight = height / CGFloat(yAxisValues.count - 1)
                        
                        ZStack(alignment: .topTrailing) {
                            ForEach(Array(yAxisValues.reversed().enumerated()), id: \.offset) { index, value in
                                Text(formatYAxisValue(value))
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .position(x: 20, y: CGFloat(index) * stepHeight)
                            }
                        }
                    }
                    .frame(height: 200)
                }
                .frame(width: 45)
                .padding(.trailing, 4)
                
                // Scrollable chart area
                VStack(spacing: 4) {
                    if needsScroll {
                        ScrollView(.horizontal, showsIndicators: true) {
                            chartContent
                                .frame(width: chartWidth, height: 200)
                        }
                        .scrollIndicators(.visible)
                    } else {
                        chartContent
                            .frame(height: 200)
                    }
                    
                    // Scroll hint
                    if needsScroll {
                        HStack(spacing: 4) {
                            Spacer()
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 10))
                            Text("Scroll for more")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                    }
                }
            }
            
            // Time range indicator
            HStack {
                Image(systemName: "clock")
                    .font(.caption2)
                Text(timeRangeDescription)
                    .font(.caption2)
                Spacer()
                Text("Last updated: \(formatLastUpdate())")
                    .font(.caption2)
            }
            .foregroundColor(.secondary)
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
    }
    
    private var timeRangeDescription: String {
        switch timeRange {
        case .hour: return "Last 60 minutes"
        case .day: return "Last 24 hours"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        }
    }
    
    private func formatLastUpdate() -> String {
        guard let last = sortedReadings.last else { return "N/A" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: last.timestamp, relativeTo: Date())
    }
    
    private var chartContent: some View {
        Chart(sortedReadings) { reading in
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
                            metric.color.opacity(0.25),
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
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
                
                // Data points (only show if not too many)
                if sortedReadings.count <= 30 {
                    PointMark(
                        x: .value("Time", reading.timestamp),
                        y: .value(metric.displayName, value)
                    )
                    .foregroundStyle(.white)
                    .symbolSize(24)
                    
                    PointMark(
                        x: .value("Time", reading.timestamp),
                        y: .value(metric.displayName, value)
                    )
                    .foregroundStyle(metric.color)
                    .symbolSize(12)
                }
            }
        }
        .chartYScale(domain: yAxisRange.min...yAxisRange.max)
        .chartYAxis(.hidden) // Hide built-in Y-axis since we have custom sticky one
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: xAxisMarkCount)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisTick(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.gray.opacity(0.5))
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        VStack(spacing: 1) {
                            Text(formatXAxisTime(date))
                                .font(.system(size: 8, weight: .medium))
                            if shouldShowDate(date) {
                                Text(formatXAxisDate(date))
                                    .font(.system(size: 7))
                                    .foregroundStyle(Color.secondary.opacity(0.8))
                            }
                        }
                        .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartPlotStyle { plotArea in
            plotArea
                .background(Color(.systemGray6).opacity(0.3))
                .cornerRadius(8)
        }
    }
    
    // Format Y-axis values based on metric
    private func formatYAxisValue(_ value: Double) -> String {
        switch metric {
        case .co2:
            if value >= 1000 {
                return String(format: "%.1fk", value / 1000)
            }
            return String(format: "%.0f", value)
        case .temperature:
            return String(format: "%.0f°", value)
        case .humidity:
            return String(format: "%.0f%%", value)
        }
    }
    
    // Format X-axis time
    private func formatXAxisTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        
        switch timeRange {
        case .hour, .day:
            formatter.dateFormat = "HH:mm"
        case .week:
            formatter.dateFormat = "HH:mm"
        case .month:
            formatter.dateFormat = "dd"
        }
        
        return formatter.string(from: date)
    }
    
    // Format X-axis date (shown below time for longer ranges)
    private func formatXAxisDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        
        switch timeRange {
        case .hour:
            return ""
        case .day:
            formatter.dateFormat = "MMM d"
        case .week, .month:
            formatter.dateFormat = "MMM d"
        }
        
        return formatter.string(from: date)
    }
    
    // Determine if date should be shown below time
    private func shouldShowDate(_ date: Date) -> Bool {
        switch timeRange {
        case .hour:
            return false
        case .day:
            // Show date at midnight or start/end
            let hour = Calendar.current.component(.hour, from: date)
            return hour == 0 || hour == 12
        case .week, .month:
            return true
        }
    }
}

struct StatisticsCard: View {
    let readings: [SensorReading]
    let metric: SensorMetric
    let userSettings: UserSettings
    
    private var statistics: (min: Double, max: Double, avg: Double) {
        let values = readings.map { metric.getValue(from: $0, userSettings: userSettings) }.filter { $0 > 0 }
        guard !values.isEmpty else { return (0, 0, 0) }
        
        return (
            min: values.min() ?? 0,
            max: values.max() ?? 0,
            avg: values.reduce(0, +) / Double(values.count)
        )
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundColor(metric.color)
                Text("Statistics")
                    .font(.headline)
            }
            
            HStack(spacing: 12) {
                StatisticItem(
                    title: "Minimum",
                    value: metric.formatValue(statistics.min, userSettings: userSettings),
                    icon: "arrow.down.circle.fill",
                    color: .blue
                )
                
                StatisticItem(
                    title: "Average",
                    value: metric.formatValue(statistics.avg, userSettings: userSettings),
                    icon: "equal.circle.fill",
                    color: metric.color
                )
                
                StatisticItem(
                    title: "Maximum",
                    value: metric.formatValue(statistics.max, userSettings: userSettings),
                    icon: "arrow.up.circle.fill",
                    color: .red
                )
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
    }
}

struct StatisticItem: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16))
                .foregroundColor(color.opacity(0.8))
            
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundColor(color)
            
            Text(title)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.1))
        .cornerRadius(8)
    }
}

struct RecentReadingsCard: View {
    let readings: [SensorReading]
    let userSettings: UserSettings
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundColor(.purple)
                Text("Recent Readings")
                    .font(.headline)
                Spacer()
                Text("\(readings.count) entries")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if readings.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.title)
                            .foregroundColor(.secondary)
                        Text("No recent readings")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                LazyVStack(spacing: 6) {
                    ForEach(readings) { reading in
                        ReadingRow(reading: reading, userSettings: userSettings)
                    }
                }
            }
        }
        .padding()
        .background(Color(.systemBackground))
        .cornerRadius(16)
        .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 2)
    }
}

struct ReadingRow: View {
    let reading: SensorReading
    let userSettings: UserSettings
    
    var body: some View {
        HStack(spacing: 12) {
            // Time indicator
            VStack(alignment: .leading, spacing: 2) {
                Text(formatTime(reading.timestamp))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.primary)
                
                Text(formatDate(reading.timestamp))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .frame(width: 60, alignment: .leading)
            
            // Divider line
            Rectangle()
                .fill(Color.gray.opacity(0.2))
                .frame(width: 1, height: 30)
            
            Spacer()
            
            // Metric badges
            HStack(spacing: 8) {
                MetricBadge(
                    value: formatCO2(reading.co2Value),
                    color: getAirQualityLevel(co2: reading.co2Value).color,
                    icon: "aqi.medium"
                )
                
                MetricBadge(
                    value: formatTemperatureForUser(reading.temperature, reading.isCelsius, userUnit: userSettings.temperatureUnit),
                    color: .orange,
                    icon: "thermometer"
                )
                
                MetricBadge(
                    value: formatHumidity(reading.humidity),
                    color: .blue,
                    icon: "humidity"
                )
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 8)
        .background(Color(.systemGray6).opacity(0.5))
        .cornerRadius(10)
    }
}

struct MetricBadge: View {
    let value: String
    let color: Color
    var icon: String? = nil
    
    var body: some View {
        HStack(spacing: 3) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 9))
            }
            Text(value)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15))
        .foregroundColor(color)
        .cornerRadius(6)
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
    
    // Default Y-axis range when no data is available
    var defaultRange: (min: Double, max: Double) {
        switch self {
        case .co2: return (min: 400, max: 2000)
        case .temperature: return (min: 15, max: 35)
        case .humidity: return (min: 20, max: 80)
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

// MARK: - Sync Progress Banner
struct SyncProgressBanner: View {
    let receivedCount: Int
    
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: .white))
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Syncing Historical Data")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                Text("\(receivedCount) samples received")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
            
            Spacer()
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.blue)
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
        .padding(.horizontal)
        .padding(.bottom, 8)
    }
}

// MARK: - Sync Completed Banner
struct SyncCompletedBanner: View {
    let totalReceived: Int
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundColor(.white)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync Complete")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                Text(totalReceived > 0 ? "\(totalReceived) samples synced" : "Already up to date")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
            }
            
            Spacer()
            
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.green)
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
        .padding(.horizontal)
        .padding(.bottom, 8)
        .onAppear {
            // Auto-dismiss after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                onDismiss()
            }
        }
    }
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
