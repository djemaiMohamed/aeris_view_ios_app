import SwiftUI
import CoreBluetooth

struct DevicePairingView: View {
    @ObservedObject var bleManager: BLEManager
    @State private var isScanning = false
    
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
                } else if isScanning {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                        
                        Text("Scanning for devices...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                } else {
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
                
                // Auto-connect to Air Quality device button
                if !bleManager.getAirQualityDevices().isEmpty {
                    Button(action: {
                        let _ = bleManager.connectToFirstAirQualityDevice()
                    }) {
                        HStack {
                            Image(systemName: "leaf.fill")
                            Text("Connect to Air Quality Device")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.green)
                        .cornerRadius(12)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 10)
                }
                
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
                .padding(.bottom, 30)
            }
            .navigationBarHidden(true)
        }
    }
}

struct DeviceRow: View {
    let peripheral: CBPeripheral
    let isConnecting: Bool
    let onTap: () -> Void
    @ObservedObject var bleManager: BLEManager
    
    private var isAirQualityDevice: Bool {
        bleManager.isAirQualityDevice(peripheral)
    }
    
    private var devicePriority: Int {
        bleManager.getDevicePriority(peripheral, rssi: NSNumber(value: -60), advertisedServices: [])
    }
    
    var body: some View {
        Button(action: onTap) {
            HStack {
                // Device type icon
                Image(systemName: isAirQualityDevice ? "leaf.fill" : "sensor.fill")
                    .foregroundColor(isAirQualityDevice ? .green : .blue)
                    .font(.title2)
                
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(peripheral.name ?? "Unknown Device")
                            .font(.headline)
                            .foregroundColor(.primary)
                        
                        if isAirQualityDevice {
                            Text("PRIORITY")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.green)
                                .cornerRadius(4)
                        }
                    }
                    
                    HStack {
                        Text(peripheral.identifier.uuidString.prefix(8) + "...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Spacer()
                        
                        if isAirQualityDevice {
                            Text("Air Quality Device")
                                .font(.caption)
                                .foregroundColor(.green)
                                .fontWeight(.medium)
                        } else {
                            Text("Priority: \(devicePriority)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                
                Spacer()
                
                if isConnecting {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    Image(systemName: "chevron.right")
                        .foregroundColor(isAirQualityDevice ? .green : .blue)
                }
            }
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isAirQualityDevice ? Color.green.opacity(0.1) : Color.clear)
            )
        }
        .disabled(isConnecting)
    }
}

#Preview {
    DevicePairingView(bleManager: BLEManager())
}
