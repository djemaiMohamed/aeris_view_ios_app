import SwiftUI
import SwiftData
import UIKit

struct AccountView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var userSettings: [UserSettings]
    @State private var isEditing = false
    @State private var tempUserName = ""
    @State private var tempUserEmail = ""
    
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
                // Profile Section
                Section {
                    VStack(spacing: 16) {
                        // Profile Image
                        Circle()
                            .fill(Color.blue.gradient)
                            .frame(width: 80, height: 80)
                            .overlay {
                                Text(getInitials(from: currentSettings.userName))
                                    .font(.title)
                                    .fontWeight(.bold)
                                    .foregroundColor(.white)
                            }
                        
                        if isEditing {
                            VStack(spacing: 12) {
                                TextField("Name", text: $tempUserName)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                
                                TextField("Email", text: $tempUserEmail)
                                    .textFieldStyle(RoundedBorderTextFieldStyle())
                                    .keyboardType(.emailAddress)
                                    .autocapitalization(.none)
                            }
                        } else {
                            VStack(spacing: 4) {
                                Text(currentSettings.userName.isEmpty ? "Tap to add name" : currentSettings.userName)
                                    .font(.title2)
                                    .fontWeight(.semibold)
                                
                                Text(currentSettings.userEmail.isEmpty ? "Tap to add email" : currentSettings.userEmail)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical)
                    .onTapGesture {
                        if !isEditing {
                            startEditing()
                        }
                    }
                }
                
                // Account Settings Section
                Section("Account Settings") {
                    AccountSettingRow(
                        icon: "bell.fill",
                        title: "Notifications",
                        subtitle: currentSettings.notificationsEnabled ? "Enabled" : "Disabled",
                        color: .purple
                    )
                    
                    AccountSettingRow(
                        icon: "thermometer",
                        title: "Temperature Unit",
                        subtitle: currentSettings.temperatureUnit.rawValue,
                        color: .orange
                    )
                    
                    AccountSettingRow(
                        icon: "exclamationmark.triangle.fill",
                        title: "CO2 Alert Threshold",
                        subtitle: "\(Int(currentSettings.co2AlertThreshold)) PPM",
                        color: .red
                    )
                }
                
                // Usage Statistics Section
                Section("Usage Statistics") {
                    UsageStatsView()
                }
                
                // Support Section
                Section("Support") {
                    NavigationLink {
                        HelpView()
                    } label: {
                        AccountSettingRow(
                            icon: "questionmark.circle.fill",
                            title: "Help & FAQ",
                            subtitle: nil,
                            color: .blue
                        )
                    }
                    
                    Button {
                        sendFeedback()
                    } label: {
                        AccountSettingRow(
                            icon: "envelope.fill",
                            title: "Send Feedback",
                            subtitle: nil,
                            color: .green
                        )
                    }
                    
                    NavigationLink {
                        AboutView()
                    } label: {
                        AccountSettingRow(
                            icon: "info.circle.fill",
                            title: "About",
                            subtitle: nil,
                            color: .gray
                        )
                    }
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isEditing ? "Save" : "Edit") {
                        if isEditing {
                            saveChanges()
                        } else {
                            startEditing()
                        }
                    }
                }
            }
        }
    }
    
    private func getInitials(from name: String) -> String {
        if name.isEmpty { return "U" }
        
        let components = name.components(separatedBy: " ")
        let initials = components.compactMap { $0.first }.map { String($0) }
        
        if initials.count >= 2 {
            return "\(initials[0])\(initials[1])".uppercased()
        } else if let first = initials.first {
            return first.uppercased()
        } else {
            return "U"
        }
    }
    
    private func startEditing() {
        tempUserName = currentSettings.userName
        tempUserEmail = currentSettings.userEmail
        isEditing = true
    }
    
    private func saveChanges() {
        currentSettings.userName = tempUserName
        currentSettings.userEmail = tempUserEmail
        
        do {
            try modelContext.save()
            isEditing = false
        } catch {
            print("Error saving user settings: \(error)")
        }
    }
    
    private func sendFeedback() {
        if let url = URL(string: "mailto:feedback@airqualitymonitor.com?subject=Air Quality Monitor Feedback") {
            UIApplication.shared.open(url)
        }
    }
}

struct AccountSettingRow: View {
    let icon: String
    let title: String
    let subtitle: String?
    let color: Color
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundColor(.primary)
                
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
        }
    }
}

struct UsageStatsView: View {
    @Query private var readings: [SensorReading]
    
    private var stats: (totalReadings: Int, daysActive: Int, avgCO2: Double) {
        let total = readings.count
        
        let uniqueDays = Set(readings.map { Calendar.current.startOfDay(for: $0.timestamp) }).count
        
        let avgCO2 = readings.isEmpty ? 0 : readings.map(\.co2Value).reduce(0, +) / Double(readings.count)
        
        return (total, uniqueDays, avgCO2)
    }
    
    var body: some View {
        VStack(spacing: 12) {
            AccountStatisticItem(
                title: "Total Readings",
                value: "\(stats.totalReadings)",
                icon: "chart.bar.fill",
                color: .blue
            )
            
            AccountStatisticItem(
                title: "Days Active",
                value: "\(stats.daysActive)",
                icon: "calendar.badge.clock",
                color: .green
            )
            
            AccountStatisticItem(
                title: "Average CO2",
                value: formatCO2(stats.avgCO2),
                icon: "aqi.medium",
                color: getAirQualityLevel(co2: stats.avgCO2).color
            )
        }
    }
}

struct AccountStatisticItem: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 24)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                
                Text(value)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .foregroundColor(color)
            }
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct HelpView: View {
    var body: some View {
        List {
            Section("Getting Started") {
                HelpItem(
                    question: "How do I pair my air quality sensor?",
                    answer: "Make sure your sensor is in pairing mode, then go to the Home tab and tap 'Scan for Devices'. Select your sensor from the list to connect."
                )
                
                HelpItem(
                    question: "Why isn't my sensor connecting?",
                    answer: "Ensure Bluetooth is enabled, your sensor is nearby and in pairing mode. Try restarting both the app and your sensor."
                )
            }
            
            Section("Understanding Readings") {
                HelpItem(
                    question: "What do the CO2 levels mean?",
                    answer: "CO2 levels are measured in PPM (Parts Per Million). 400-1000 PPM is good, 1000-2000 is moderate, above 2000 requires ventilation."
                )
                
                HelpItem(
                    question: "How accurate are the readings?",
                    answer: "The sensor provides real-time measurements with professional-grade accuracy. Readings update based on your configured measurement interval."
                )
            }
            
            Section("Notifications") {
                HelpItem(
                    question: "When will I receive alerts?",
                    answer: "You'll receive notifications when CO2 levels exceed your threshold for more than 5 minutes. You can adjust the threshold in Settings."
                )
            }
        }
        .navigationTitle("Help & FAQ")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HelpItem: View {
    let question: String
    let answer: String
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    Text(question)
                        .font(.headline)
                        .foregroundColor(.primary)
                        .multilineTextAlignment(.leading)
                    
                    Spacer()
                    
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                }
            }
            
            if isExpanded {
                Text(answer)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 4)
    }
}

struct AboutView: View {
    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 16) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 80))
                    .foregroundColor(.green)
                
                Text("Air Quality Monitor")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Version 1.0.0")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                Text("About This App")
                    .font(.headline)
                
                Text("Air Quality Monitor helps you track and improve your indoor environment by monitoring CO2, temperature, and humidity levels in real-time. Get insights, receive alerts, and maintain a healthy living space.")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Developer")
                    .font(.headline)
                
                Text("Developed by Mohamed Djemai with ❤️ for healthier indoor environments.")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    AccountView()
        .modelContainer(for: [UserSettings.self, SensorReading.self])
}
