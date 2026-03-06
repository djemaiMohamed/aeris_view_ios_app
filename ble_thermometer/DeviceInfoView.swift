import SwiftUI

struct DeviceInfoView: View {
    @ObservedObject var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss
    @State private var showRenameAlert = false
    @State private var renameText = ""
    
    var body: some View {
        NavigationView {
            List {
                Section("Device Information") {
                    if let device = bleManager.activePeripheral ?? bleManager.connectedPeripheral {
                        InfoRow(label: "Display Name", value: bleManager.displayName(for: device))
                        InfoRow(label: "BLE Name", value: device.name ?? "Unknown")
                        Button {
                            renameText = bleManager.displayName(for: device)
                            showRenameAlert = true
                        } label: {
                            HStack {
                                Text("Rename Device")
                                    .foregroundColor(.blue)
                                Spacer()
                                Image(systemName: "pencil")
                                    .foregroundColor(.blue)
                            }
                        }
                    } else {
                        InfoRow(label: "Name", value: "Unknown")
                    }
                    InfoRow(label: "Identifier", value: (bleManager.activePeripheral ?? bleManager.connectedPeripheral)?.identifier.uuidString ?? "N/A")
                    InfoRow(label: "State", value: bleManager.connectionStatus)
                    InfoRow(label: "Bonded", value: bleManager.isBonded ? "Yes" : "No")
                }
                
                Section("Current Readings") {
                    InfoRow(label: "CO2", value: formatCO2(bleManager.co2Value))
                    InfoRow(label: "Temperature", value: formatTemperature(bleManager.tempValue, isCelsius: bleManager.isTempCelsius))
                    InfoRow(label: "Humidity", value: formatHumidity(bleManager.humValue))
                    InfoRow(label: "Air Quality", value: bleManager.airQualityLevel.rawValue)
                }
                
                Section("Connection") {
                    if bleManager.connectedPeripheral != nil {
                        Button("Disconnect Device") {
                            if let peripheral = bleManager.connectedPeripheral {
                                bleManager.disconnect(peripheral: peripheral)
                            }
                        }
                        .foregroundColor(.red)
                    } else if let bondedDevice = bleManager.bondedPeripheral {
                        Button("Connect to \(bondedDevice.name ?? "Device")") {
                            bleManager.connect(peripheral: bondedDevice)
                        }
                        .foregroundColor(.green)
                        
                        Button("Scan for Devices") {
                            bleManager.startScan()
                            dismiss()
                        }
                        .foregroundColor(.blue)
                    } else {
                        Button("Scan for Devices") {
                            bleManager.startScan()
                            dismiss()
                        }
                        .foregroundColor(.blue)
                    }
                }
            }
            .navigationTitle("Device Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Rename Device", isPresented: $showRenameAlert) {
                TextField("Device name", text: $renameText)
                Button("Save") {
                    if let device = bleManager.activePeripheral ?? bleManager.connectedPeripheral {
                        bleManager.renameDevice(device, to: renameText)
                    }
                }
                Button("Reset to Default", role: .destructive) {
                    if let device = bleManager.activePeripheral ?? bleManager.connectedPeripheral {
                        bleManager.renameDevice(device, to: nil)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Enter a custom name (e.g. Living Room, Bedroom)")
            }
        }
    }
}

struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.medium)
        }
    }
}

#Preview {
    DeviceInfoView(bleManager: BLEManager())
}
