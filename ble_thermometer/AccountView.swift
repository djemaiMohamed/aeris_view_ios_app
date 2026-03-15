import SwiftUI
import SwiftData
import UIKit
import PhotosUI

struct AccountView: View {
    @Environment(\.modelContext) private var modelContext
    @State private var userSettings: [UserSettings] = []
    @State private var didEnsureSettings = false
    @State private var showFeedbackSheet = false
    
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
                        showFeedbackSheet = true
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
                
                // Company Links Section
                Section("Connect With Us") {
                    Button {
                        if let url = URL(string: "https://www.getaeris.ca") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        AccountSettingRow(
                            icon: "globe",
                            title: "Visit Our Website",
                            subtitle: "getaeris.ca",
                            color: .blue
                        )
                    }
                    
                    Button {
                        if let url = URL(string: "https://www.instagram.com/aeris_tech/") {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        AccountSettingRow(
                            icon: "camera.fill",
                            title: "Follow on Instagram",
                            subtitle: "@aeris_tech",
                            color: .pink
                        )
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
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.large)
            .sheet(isPresented: $showFeedbackSheet) {
                FeedbackView()
            }
            .task {
                loadUserSettings()
                ensureSettings()
            }
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
    @Environment(\.modelContext) private var modelContext
    @State private var readings: [SensorReading] = []

    private func loadReadings() {
        let descriptor = FetchDescriptor<SensorReading>()
        if let results = try? modelContext.fetch(descriptor) {
            readings = results
        }
    }
    
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
        .task { loadReadings() }
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
                
                Text("Aeris View")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Version 1.0")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                Text("About This App")
                    .font(.headline)
                
                Text("Aeris View helps you track and improve your indoor environment by monitoring CO2, temperature, and humidity levels in real-time. Get insights, receive alerts, and maintain a healthy living space.")
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Developer")
                    .font(.headline)
                
                Text("Developed by Aeris Technology with ❤️ for healthier indoor environments.")
                    .font(.body)
                    .foregroundColor(.secondary)
                
                Button {
                    if let url = URL(string: "https://www.getaeris.ca") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("getaeris.ca")
                        .font(.body)
                        .foregroundColor(.blue)
                }
            }
            
            Spacer()
        }
        .padding()
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct FeedbackView: View {
    @Environment(\.dismiss) private var dismiss
    
    @State private var feedbackText = ""
    @State private var userName = ""
    @State private var userEmail = ""
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var attachedImage: UIImage? = nil
    @State private var showConfirmation = false
    @State private var isSubmitting = false

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { id, element in
            guard let value = element.value as? Int8, value != 0 else { return id }
            return id + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
    }

    private var systemVersion: String {
        UIDevice.current.systemVersion
    }

    var body: some View {
        NavigationView {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("We'd love to hear from you! 💬")
                            .font(.headline)
                        Text("Your feedback helps us improve Aeris View. Positive reviews may be featured as a testimonial on our website — so don't hold back!")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Your Details (Optional)") {
                    TextField("Your Name", text: $userName)
                    TextField("Your Email", text: $userEmail)
                        .keyboardType(.emailAddress)
                        .autocapitalization(.none)
                }

                Section("Your Feedback") {
                    TextEditor(text: $feedbackText)
                        .frame(minHeight: 120)
                        .overlay(
                            Group {
                                if feedbackText.isEmpty {
                                    Text("Tell us what you think, what you love, or what could be better...")
                                        .foregroundColor(.secondary)
                                        .padding(.top, 8)
                                        .padding(.leading, 4)
                                        .allowsHitTesting(false)
                                }
                            },
                            alignment: .topLeading
                        )
                }

                Section("Attach a Screenshot (Optional)") {
                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        HStack {
                            Image(systemName: "photo.badge.plus")
                                .foregroundColor(.blue)
                            Text(attachedImage == nil ? "Choose Screenshot or Data" : "Image Selected ✓")
                                .foregroundColor(attachedImage == nil ? .primary : .green)
                        }
                    }
                    .onChange(of: selectedPhotoItem) { _, newItem in
                        Task {
                            if let newItem,
                               let data = try? await newItem.loadTransferable(type: Data.self),
                               let image = UIImage(data: data) {
                                attachedImage = image
                            }
                        }
                    }

                    if let image = attachedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 180)
                            .cornerRadius(8)
                    }
                }

                Section("Device Info (Auto-filled)") {
                    LabeledContent("Device", value: deviceModel)
                    LabeledContent("iOS Version", value: systemVersion)
                    LabeledContent("App Version", value: appVersion)
                }

                Section {
                    Button {
                        submitFeedback()
                    } label: {
                        HStack {
                            Spacer()
                            if isSubmitting {
                                ProgressView()
                            } else {
                                Text("Send Feedback")
                                    .fontWeight(.semibold)
                                    .foregroundColor(.white)
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(feedbackText.isEmpty ? Color.gray : Color.green)
                    .disabled(feedbackText.isEmpty || isSubmitting)
                }
            }
            .navigationTitle("Send Feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") { dismiss() }
                }
            }
            .alert("Thank You! 🎉", isPresented: $showConfirmation) {
                Button("Close", role: .cancel) { dismiss() }
            } message: {
                Text("Your feedback has been sent to the Aeris team. We read every message and truly appreciate you taking the time. If your review is glowing, it may be featured on our website!")
            }
        }
    }

    private func submitFeedback() {
        isSubmitting = true
        let subject = "Aeris View Feedback – v\(appVersion)"
        let nameInfo = userName.isEmpty ? "" : "Name: \(userName)\n"
        let emailInfo = userEmail.isEmpty ? "" : "Email: \(userEmail)\n"
        let body = """
        \(nameInfo)\(emailInfo)
        Feedback:
        \(feedbackText)

        ---
        Device: \(deviceModel)
        iOS: \(systemVersion)
        App Version: \(appVersion)
        """
        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let mailURLString = "mailto:support@getaeris.ca?subject=\(encodedSubject)&body=\(encodedBody)"
        if let url = URL(string: mailURLString) {
            UIApplication.shared.open(url) { _ in
                isSubmitting = false
                showConfirmation = true
            }
        } else {
            isSubmitting = false
        }
    }
}

#Preview {
    AccountView()
        .modelContainer(for: [UserSettings.self, SensorReading.self])
}
