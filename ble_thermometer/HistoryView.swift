import SwiftUI
import SwiftData
import Charts

// MARK: - Optimized Data Manager for Lazy Loading
class HistoryDataManager: ObservableObject {
    @Published var visibleReadings: [SensorReading] = []
    @Published var isLoading: Bool = false
    @Published var totalCount: Int = 0
    @Published var visibleWindow: (start: Date, end: Date)?
    
    private var allReadingsCache: [SensorReading] = []
    private var modelContext: ModelContext?
    private var deviceId: String?
    
    // Window size for visible data (number of points to load at once)
    private let windowSize: Int = 100
    
    func configure(context: ModelContext, deviceId: String?) {
        self.modelContext = context
        self.deviceId = deviceId
    }
    
    /// Fetch readings for a specific time range with optimized loading
    func fetchReadings(for timeRange: HistoryTimeRange, deviceId: String?) async {
        await MainActor.run { isLoading = true }
        
        let now = Date()
        let startDate = timeRange.startDate(from: now)
        
        guard let context = modelContext else {
            await MainActor.run { isLoading = false }
            return
        }
        
        // Build predicate for time range and device
        var predicate: Predicate<SensorReading>
        if let deviceId = deviceId {
            predicate = #Predicate<SensorReading> { reading in
                reading.timestamp >= startDate && reading.timestamp <= now && reading.deviceId == deviceId
            }
        } else {
            predicate = #Predicate<SensorReading> { reading in
                reading.timestamp >= startDate && reading.timestamp <= now
            }
        }
        
        let descriptor = FetchDescriptor<SensorReading>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        
        do {
            let readings = try context.fetch(descriptor)
            
            // Downsample if too many points
            let downsampled = downsample(readings, maxPoints: 300)
            
            await MainActor.run {
                self.allReadingsCache = downsampled
                self.totalCount = readings.count
                
                // Initially show the last portion of data (most recent)
                self.loadWindowAtEnd()
                self.isLoading = false
            }
        } catch {
            print("Failed to fetch readings: \(error)")
            await MainActor.run { isLoading = false }
        }
    }
    
    /// Load a window of data centered around a specific date
    func loadWindow(around date: Date) {
        guard !allReadingsCache.isEmpty else { return }
        
        // Find the index closest to the date
        let targetIndex = allReadingsCache.firstIndex { $0.timestamp >= date } ?? allReadingsCache.count - 1
        
        // Calculate window bounds
        let halfWindow = windowSize / 2
        let startIndex = max(0, targetIndex - halfWindow)
        let endIndex = min(allReadingsCache.count, startIndex + windowSize)
        
        visibleReadings = Array(allReadingsCache[startIndex..<endIndex])
        
        if let first = visibleReadings.first, let last = visibleReadings.last {
            visibleWindow = (start: first.timestamp, end: last.timestamp)
        }
    }
    
    /// Load the most recent data (end of the dataset)
    func loadWindowAtEnd() {
        guard !allReadingsCache.isEmpty else {
            visibleReadings = []
            return
        }
        
        let startIndex = max(0, allReadingsCache.count - windowSize)
        visibleReadings = Array(allReadingsCache[startIndex...])
        
        if let first = visibleReadings.first, let last = visibleReadings.last {
            visibleWindow = (start: first.timestamp, end: last.timestamp)
        }
    }
    
    /// Load earlier data (scroll left)
    func loadEarlierData() {
        guard !allReadingsCache.isEmpty, let currentWindow = visibleWindow else { return }
        
        // Find current start index
        guard let currentStartIndex = allReadingsCache.firstIndex(where: { $0.timestamp >= currentWindow.start }) else { return }
        
        // Already at the beginning
        if currentStartIndex == 0 { return }
        
        // Load previous window
        let newStartIndex = max(0, currentStartIndex - windowSize / 2)
        let newEndIndex = min(allReadingsCache.count, newStartIndex + windowSize)
        
        visibleReadings = Array(allReadingsCache[newStartIndex..<newEndIndex])
        
        if let first = visibleReadings.first, let last = visibleReadings.last {
            visibleWindow = (start: first.timestamp, end: last.timestamp)
        }
    }
    
    /// Load later data (scroll right)
    func loadLaterData() {
        guard !allReadingsCache.isEmpty, let currentWindow = visibleWindow else { return }
        
        // Find current end index
        guard let currentEndIndex = allReadingsCache.lastIndex(where: { $0.timestamp <= currentWindow.end }) else { return }
        
        // Already at the end
        if currentEndIndex >= allReadingsCache.count - 1 { return }
        
        // Load next window
        let newEndIndex = min(allReadingsCache.count, currentEndIndex + windowSize / 2 + 1)
        let newStartIndex = max(0, newEndIndex - windowSize)
        
        visibleReadings = Array(allReadingsCache[newStartIndex..<newEndIndex])
        
        if let first = visibleReadings.first, let last = visibleReadings.last {
            visibleWindow = (start: first.timestamp, end: last.timestamp)
        }
    }
    
    /// Check if more data is available in each direction
    var canLoadEarlier: Bool {
        guard let window = visibleWindow, let first = allReadingsCache.first else { return false }
        return first.timestamp < window.start
    }
    
    var canLoadLater: Bool {
        guard let window = visibleWindow, let last = allReadingsCache.last else { return false }
        return last.timestamp > window.end
    }
    
    /// Get all cached readings for statistics (doesn't load into visible)
    var allReadings: [SensorReading] {
        return allReadingsCache
    }
    
    /// Downsample readings using LTTB-like algorithm for performance
    private func downsample(_ readings: [SensorReading], maxPoints: Int) -> [SensorReading] {
        guard readings.count > maxPoints else { return readings }
        
        let step = Double(readings.count) / Double(maxPoints)
        var result: [SensorReading] = []
        result.reserveCapacity(maxPoints)
        
        for i in 0..<maxPoints {
            let index = Int(Double(i) * step)
            if index < readings.count {
                result.append(readings[index])
            }
        }
        
        // Always include the last reading
        if let last = readings.last, result.last?.id != last.id {
            result.append(last)
        }
        
        return result
    }
}

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var userSettings: [UserSettings] = []
    @ObservedObject var bleManager: BLEManager
    @StateObject private var dataManager = HistoryDataManager()
    
    @State private var selectedTimeRange: HistoryTimeRange = .day
    @State private var selectedMetric: SensorMetric = .co2
    
    private var currentSettings: UserSettings {
        userSettings.first ?? UserSettings()
    }

    private func loadUserSettings() {
        let descriptor = FetchDescriptor<UserSettings>()
        if let results = try? modelContext.fetch(descriptor) {
            userSettings = results
        }
    }
    
    private func refreshData() {
        dataManager.configure(context: modelContext, deviceId: bleManager.activePeripheral?.identifier.uuidString)
        Task {
            await dataManager.fetchReadings(
                for: selectedTimeRange,
                deviceId: bleManager.activePeripheral?.identifier.uuidString
            )
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
                    refreshData()
                }
                
                if dataManager.isLoading {
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Loading data...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if dataManager.visibleReadings.isEmpty {
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
                            
                            // Optimized Chart Card with navigation
                            OptimizedChartCard(
                                dataManager: dataManager,
                                metric: selectedMetric,
                                userSettings: currentSettings,
                                timeRange: selectedTimeRange
                            )
                            
                            // Statistics Card (uses all data for accurate stats)
                            StatisticsCard(
                                readings: dataManager.allReadings,
                                metric: selectedMetric,
                                userSettings: currentSettings
                            )
                            
                            // Recent Readings List (only show last 10)
                            RecentReadingsCard(
                                readings: Array(dataManager.visibleReadings.suffix(10).reversed()),
                                userSettings: currentSettings
                            )
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(action: {
                            bleManager.requestSyncData()
                        }) {
                            Label("Sync Recent Data", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: {
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
                        refreshData() // Refresh after sync completes
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if case .failed(let message) = bleManager.syncState {
                    SyncFailedBanner(message: message) {
                        bleManager.syncState = .idle
                    }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: bleManager.syncState)
            .onAppear {
                loadUserSettings()
                refreshData()
            }
            .onChange(of: bleManager.activePeripheral?.identifier) { _, _ in
                refreshData()
            }
            .onChange(of: bleManager.syncState) { oldValue, newValue in
                // Refresh data when sync completes
                if case .completed = newValue {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        refreshData()
                    }
                }
            }
        }
    }
}

// MARK: - Optimized Chart Card with Navigation
struct OptimizedChartCard: View {
    @ObservedObject var dataManager: HistoryDataManager
    let metric: SensorMetric
    let userSettings: UserSettings
    let timeRange: HistoryTimeRange
    
    // Sorted readings for proper chart display
    private var sortedReadings: [SensorReading] {
        dataManager.visibleReadings.sorted { $0.timestamp < $1.timestamp }
    }
    
    // Calculate Y-axis range for the metric
    private var yAxisRange: (min: Double, max: Double) {
        let values = sortedReadings.map { metric.getValue(from: $0, userSettings: userSettings) }.filter { $0 > 0 }
        guard !values.isEmpty else {
            return metric.defaultRange
        }
        let minVal = values.min() ?? 0
        let maxVal = values.max() ?? 100
        let padding = (maxVal - minVal) * 0.1
        return (min: max(0, minVal - padding), max: maxVal + padding)
    }
    
    // Y-axis values for display
    private var yAxisValues: [Double] {
        let range = yAxisRange
        let step = (range.max - range.min) / 5
        guard step > 0 else {
            let value = range.min
            if value == 0 { return [0, 20, 40, 60, 80, 100] }
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
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with data info
            HStack {
                Image(systemName: metric.iconName)
                    .font(.title3)
                    .foregroundColor(metric.color)
                
                Text("\(metric.displayName) Over Time")
                    .font(.headline)
                
                Spacer()
                
                // Data point count badge
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(sortedReadings.count) visible")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if dataManager.totalCount > sortedReadings.count {
                        Text("of \(dataManager.totalCount) total")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
            
            // Navigation buttons
            HStack(spacing: 12) {
                Button(action: { dataManager.loadEarlierData() }) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                        Text("Earlier")
                    }
                    .font(.caption)
                    .foregroundColor(dataManager.canLoadEarlier ? .blue : .gray)
                }
                .disabled(!dataManager.canLoadEarlier)
                
                Spacer()
                
                // Time window indicator
                if let window = dataManager.visibleWindow {
                    Text(formatTimeWindow(window))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Button(action: { dataManager.loadLaterData() }) {
                    HStack(spacing: 4) {
                        Text("Later")
                        Image(systemName: "chevron.right")
                    }
                    .font(.caption)
                    .foregroundColor(dataManager.canLoadLater ? .blue : .gray)
                }
                .disabled(!dataManager.canLoadLater)
            }
            .padding(.horizontal, 4)
            
            // Chart with Y-axis
            HStack(alignment: .top, spacing: 0) {
                // Fixed Y-axis
                VStack(alignment: .trailing, spacing: 0) {
                    Text(yAxisLabel)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(height: 16)
                    
                    GeometryReader { geometry in
                        let height = geometry.size.height
                        let stepHeight = yAxisValues.count > 1 ? height / CGFloat(yAxisValues.count - 1) : height
                        
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
                
                // Chart
                chartContent
                    .frame(height: 200)
            }
            
            // Time range and jump to end button
            HStack {
                Image(systemName: "clock")
                    .font(.caption2)
                Text(timeRangeDescription)
                    .font(.caption2)
                Spacer()
                
                if dataManager.canLoadLater {
                    Button(action: { dataManager.loadWindowAtEnd() }) {
                        HStack(spacing: 4) {
                            Text("Jump to Latest")
                            Image(systemName: "arrow.right.to.line")
                        }
                        .font(.caption2)
                        .foregroundColor(.blue)
                    }
                }
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
    
    private func formatTimeWindow(_ window: (start: Date, end: Date)) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return "\(formatter.string(from: window.start)) - \(formatter.string(from: window.end))"
    }
    
    private var chartContent: some View {
        Chart(sortedReadings) { reading in
            let value = metric.getValue(from: reading, userSettings: userSettings)
            if value > 0 {
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
                
                LineMark(
                    x: .value("Time", reading.timestamp),
                    y: .value(metric.displayName, value)
                )
                .foregroundStyle(metric.color)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.catmullRom)
                
                // Show points only if few data points
                if sortedReadings.count <= 50 {
                    PointMark(
                        x: .value("Time", reading.timestamp),
                        y: .value(metric.displayName, value)
                    )
                    .foregroundStyle(metric.color)
                    .symbolSize(sortedReadings.count <= 20 ? 20 : 8)
                }
            }
        }
        .chartYScale(domain: yAxisRange.min...yAxisRange.max)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .foregroundStyle(Color.gray.opacity(0.3))
                AxisTick(stroke: StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.gray.opacity(0.5))
                AxisValueLabel(anchor: .top) {
                    if let date = value.as(Date.self) {
                        VStack(spacing: 1) {
                            Text(formatXAxisTime(date))
                                .font(.system(size: 8, weight: .medium))
                            Text(formatXAxisDate(date))
                                .font(.system(size: 7))
                                .foregroundStyle(Color.secondary.opacity(0.8))
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
    
    private func formatYAxisValue(_ value: Double) -> String {
        switch metric {
        case .co2:
            if value >= 1000 { return String(format: "%.1fk", value / 1000) }
            return String(format: "%.0f", value)
        case .temperature:
            return String(format: "%.0f°", value)
        case .humidity:
            return String(format: "%.0f%%", value)
        }
    }
    
    private func formatXAxisTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    
    private func formatXAxisDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
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
    
    /// Calculate the start date for this time range from a given reference date
    func startDate(from date: Date) -> Date {
        switch self {
        case .hour:
            return Calendar.current.date(byAdding: .hour, value: -1, to: date) ?? date
        case .day:
            return Calendar.current.date(byAdding: .day, value: -1, to: date) ?? date
        case .week:
            return Calendar.current.date(byAdding: .weekOfYear, value: -1, to: date) ?? date
        case .month:
            return Calendar.current.date(byAdding: .month, value: -1, to: date) ?? date
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

// MARK: - Sync Failed Banner
struct SyncFailedBanner: View {
    let message: String
    let onDismiss: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundColor(.white)
            
            VStack(alignment: .leading, spacing: 2) {
                Text("Sync Failed")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                
                Text(message)
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
                .fill(Color.red)
                .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 4)
        )
        .padding(.horizontal)
        .padding(.bottom, 8)
        .onAppear {
            // Auto-dismiss after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
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
