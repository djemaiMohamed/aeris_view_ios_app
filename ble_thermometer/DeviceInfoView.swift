import SwiftUI

struct DeviceInfoView: View {
    @ObservedObject var bleManager: BLEManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                Section("Device Information") {
                    InfoRow(label: "Name", value: bleManager.connectedPeripheral?.name ?? "Unknown")
                    InfoRow(label: "Identifier", value: bleManager.connectedPeripheral?.identifier.uuidString ?? "N/A")
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
