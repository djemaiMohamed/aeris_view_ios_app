import SwiftUI
import CoreBluetooth

struct SettingsView: View {
    @ObservedObject var bleManager: BLEManager

    // Temperature settings
    @AppStorage("temperatureUnit") private var temperatureUnit: TemperatureUnit = .celsius
    @State private var temperatureUpdateFrequency: TimeInterval = 60 // Default to 1 minute

    // Humidity settings
    @State private var humidityUpdateFrequency: TimeInterval = 60 // Default to 1 minute

    // Enum for temperature unit
    enum TemperatureUnit: String, CaseIterable, Identifiable {
        case celsius = "Celsius"
        case fahrenheit = "Fahrenheit"

        var id: String { self.rawValue }
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Temperature Settings")) {
                    Picker("Temperature Unit", selection: $temperatureUnit) {
                        ForEach(TemperatureUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit)
                        }
                    }
                    .disabled(bleManager.connectedPeripheral == nil)

                    HStack {
                        Picker("Temperature and Humidity Measurement Interval", selection: $temperatureUpdateFrequency) {
                            Text("1 Second").tag(1.0)
                            Text("10 Seconds").tag(10.0)
                            Text("1 Minute").tag(60.0)
                            Text("5 Minutes").tag(300.0)
                            Text("1 Hour").tag(3600.0)
                        }
                        .pickerStyle(.menu)
                    }
                    .disabled(bleManager.connectedPeripheral == nil)
                }

                Section(header: Text("Connected Device")) {
                    if let connectedPeripheral = bleManager.connectedPeripheral {
                        Text("Device Name: \(connectedPeripheral.name ?? "Unknown Device")")
                        Button("Disconnect") {
                            bleManager.disconnect(peripheral: connectedPeripheral)
                        }
                    } else {
                        Text("No device connected.")
                    }
                }
            }
            .navigationTitle("Settings")
            .onChange(of: temperatureUpdateFrequency) { newValue in
                sendMeasurementInterval(interval: newValue)
            }
            .onAppear {
                bleManager.startScan()
            }
        }
    }

    func sendMeasurementInterval(interval: TimeInterval) {
        guard let peripheral = bleManager.connectedPeripheral,
              let characteristic = findCharacteristic(with: CBUUID(string: "2A21"), in: peripheral) else {
            print("Characteristic not found")
            return
        }

        // Convert the TimeInterval to UInt16 (seconds)
        let intervalInSeconds = UInt16(interval)

        // Convert the UInt16 to Data
        var intervalData = Data(count: 2)
        intervalData.withUnsafeMutableBytes { buffer in
            buffer.storeBytes(of: intervalInSeconds.littleEndian, as: UInt16.self)
        }

        bleManager.writeValue(for: characteristic, of: peripheral, value: intervalData)
    }

    private func findCharacteristic(with uuid: CBUUID, in peripheral: CBPeripheral) -> CBCharacteristic? {
        guard let services = peripheral.services else { return nil }
        for service in services {
            if let characteristics = service.characteristics {
                for characteristic in characteristics {
                    if characteristic.uuid == uuid {
                        return characteristic
                    }
                }
            }
        }
        return nil
    }
}
