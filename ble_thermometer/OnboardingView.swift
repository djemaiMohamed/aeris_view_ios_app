import SwiftUI
import CoreBluetooth

struct OnboardingView: View {
    @ObservedObject var bleManager: BLEManager
    var onEnableDemoMode: (() -> Void)? = nil
    @State private var currentPage = 0
    
    var body: some View {
        TabView(selection: $currentPage) {
            // Welcome Page
            OnboardingPage(
                imageName: "leaf.fill",
                title: "Welcome to Aeris View",
                description: "Monitor your indoor air quality with real-time CO2, temperature, and humidity readings.",
                pageIndex: 0
            )
            .tag(0)
            
            // Features Page
            OnboardingPage(
                imageName: "chart.line.uptrend.xyaxis",
                title: "Track Your Environment",
                description: "Get detailed insights about your air quality and receive alerts when action is needed.",
                pageIndex: 1
            )
            .tag(1)
            
            // Bluetooth Setup Page
            BluetoothSetupPage(
                bleManager: bleManager,
                pageIndex: 2,
                onEnableDemoMode: onEnableDemoMode
            )
                .tag(2)
        }
        .tabViewStyle(PageTabViewStyle())
        .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
    }
}

struct OnboardingPage: View {
    let imageName: String
    let title: String
    let description: String
    let pageIndex: Int
    
    var body: some View {
        VStack(spacing: 40) {
            Spacer()
            
            Image(systemName: imageName)
                .font(.system(size: 100))
                .foregroundColor(.blue)
            
            VStack(spacing: 20) {
                Text(title)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                
                Text(description)
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 40)
            }
            
            Spacer()
        }
        .padding()
    }
}

struct BluetoothSetupPage: View {
    @ObservedObject var bleManager: BLEManager
    let pageIndex: Int
    var onEnableDemoMode: (() -> Void)? = nil
    
    var body: some View {
        VStack(spacing: 40) {
            Spacer()
            
            Image(systemName: bleManager.isBluetoothEnabled ? "checkmark.circle.fill" : "bluetooth")
                .font(.system(size: 100))
                .foregroundColor(bleManager.isBluetoothEnabled ? .green : .blue)
            
            VStack(spacing: 20) {
                Text("Enable Bluetooth")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)
                
                Text(bleManager.isBluetoothEnabled 
                     ? "Bluetooth is enabled! You can now pair with your air quality sensor."
                     : "Please enable Bluetooth in Settings to connect to your air quality sensor.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 40)
            }
            
            if !bleManager.isBluetoothEnabled {
                Button("Open Settings") {
                    if let settingsUrl = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(settingsUrl)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Button("Continue in Demo Mode") {
                onEnableDemoMode?()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            
            Spacer()
        }
        .padding()
    }
}

#Preview {
    OnboardingView(bleManager: BLEManager())
}
