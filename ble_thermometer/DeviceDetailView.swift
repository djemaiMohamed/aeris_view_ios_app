import SwiftUI
import CoreBluetooth

struct DeviceDetailView: View {
    @ObservedObject var bleManager: BLEManager
    let peripheral: CBPeripheral

    var body: some View {
        VStack {
            Text("Device Name: \(peripheral.name ?? "N/A")")
                .font(.title)
                .padding()

            if let services = peripheral.services {
                List {
                    ForEach(services, id: \.uuid) { service in
                        ServiceSection(bleManager: bleManager, peripheral: peripheral, service: service)
                    }
                }
            } else {
                Text("No services discovered for this device.")
            }
        }
        .onAppear {
            peripheral.discoverServices(nil)
        }
    }
}

struct ServiceSection: View {
    @ObservedObject var bleManager: BLEManager
    let peripheral: CBPeripheral
    let service: CBService

    var body: some View {
        Section(header: Text("Service: \(service.uuid.uuidString)")) {
            if let characteristics = service.characteristics {
                ForEach(characteristics, id: \.uuid) { characteristic in
                    CharacteristicView(bleManager: bleManager, peripheral: peripheral, characteristic: characteristic)
                }
            } else {
                Text("No characteristics discovered for this service.")
            }
        }
    }
}

struct CharacteristicView: View {
    @ObservedObject var bleManager: BLEManager
    let peripheral: CBPeripheral
    let characteristic: CBCharacteristic
    @State private var characteristicValue: String = "N/A"
    @State private var isNotifying: Bool = false

    var body: some View {
        VStack(alignment: .leading) {
            Text("Characteristic: \(bleManager.getCharacteristicName(uuid: characteristic.uuid))")
                .font(.headline)
            Text("UUID: \(characteristic.uuid.uuidString)")
                .font(.subheadline)
            Text("Notifying: \(isNotifying ? "Enabled" : "Disabled")")
                .font(.subheadline)
            HStack {
                Button("Read Value") {
                    bleManager.readValue(for: characteristic, of: peripheral) { value in
                        characteristicValue = value
                    }
                }
                .buttonStyle(CustomButtonStyle())
                Button(isNotifying ? "Stop Notify" : "Notify") {
                    bleManager.setNotifyValue(!isNotifying, for: characteristic, of: peripheral)
                    isNotifying.toggle()
                }
                .buttonStyle(CustomButtonStyle())
            }
            Text("Value: \(characteristicValue)")
                .padding(.top, 5)
        }
        .padding(.vertical, 5)
        .onAppear {
            isNotifying = characteristic.isNotifying
        }
    }
}

struct CustomButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.blue)
            )
            .foregroundColor(.white)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}
