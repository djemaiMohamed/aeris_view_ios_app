import SwiftUI
import CoreBluetooth

struct DevicePairingView: View {
    @ObservedObject var bleManager: BLEManager
    @State private var isScanning = false
    var autoStartScan: Bool = false
    var onEnableDemoMode: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            VStack(spacing: 30) {
                // Header
                VStack(spacing: 16) {
                    Image(systemName: "sensor.tag.radiowaves.forward.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.blue)
                    
                    Text("Pair Air Quality Sensor")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                        .multilineTextAlignment(.center)
                    
                    Text("Make sure your sensor is in pairing mode and nearby.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.top, 40)
                
                // Device List
                if bleManager.peripherals.isEmpty && !isScanning {
                    VStack(spacing: 20) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        
                        Text("No devices found")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        
                        Text("Tap scan to search for air quality sensors")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else if bleManager.peripherals.isEmpty && isScanning {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        
                        Text("Scanning for devices...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
                    // Show scanning indicator above the list while still scanning
                    if isScanning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("Scanning for more devices...")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                    }

                    List {
                        ForEach(bleManager.peripherals, id: \.identifier) { peripheral in
                            DeviceRow(
                                peripheral: peripheral,
                                isConnecting: bleManager.isConnecting && bleManager.connectedPeripheral?.identifier == peripheral.identifier,
                                onTap: {
                                    bleManager.connect(peripheral: peripheral)
                                },
                                bleManager: bleManager
                            )
                        }
                    }
                    .listStyle(InsetGroupedListStyle())
                }
                
                Spacer()
                
                // Scan Button
                Button(action: {
                    if isScanning {
                        bleManager.stopScan()
                        isScanning = false
                    } else {
                        bleManager.startScan()
                        isScanning = true
                        
                        // Auto-stop scanning after 30 seconds
                        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                            if isScanning {
                                bleManager.stopScan()
                                isScanning = false
                            }
                        }
                    }
                }) {
                    HStack {
                        Image(systemName: isScanning ? "stop.circle.fill" : "magnifyingglass")
                        Text(isScanning ? "Stop Scanning" : "Scan for Devices")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(isScanning ? Color.red : Color.blue)
                    .cornerRadius(12)
                }
                .padding(.horizontal)

                Button("Continue in Demo Mode") {
                    if isScanning {
                        bleManager.stopScan()
                        isScanning = false
                    }
                    onEnableDemoMode?()
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom, 30)
            }
            .navigationBarHidden(true)
            .onAppear {
                if autoStartScan && !isScanning {
                    bleManager.startScan()
                    isScanning = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                        if isScanning {
                            bleManager.stopScan()
                            isScanning = false
                        }
                    }
                }
            }
            .onDisappear {
                if isScanning {
                    bleManager.stopScan()
                    isScanning = false
                }
            }
            .onChange(of: bleManager.connectedPeripheral) { newValue in
                if newValue != nil {
                    // Stop scanning and dismiss after brief delay
                    if isScanning {
                        bleManager.stopScan()
                        isScanning = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct DeviceRow: View {
    let peripheral: CBPeripheral
    let isConnecting: Bool
    let onTap: () -> Void
    @ObservedObject var bleManager: BLEManager
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                Image(systemName: "sensor.fill")
                    .foregroundColor(.blue)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(peripheral.name ?? "Unknown Device")
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(peripheral.identifier.uuidString.prefix(8) + "...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if isConnecting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Connecting...")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                } else {
                    Text("Tap to connect")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
            }
            .padding(.vertical, 8)
        }
        .disabled(isConnecting)
    }
}

#Preview {
    DevicePairingView(bleManager: BLEManager())
}
