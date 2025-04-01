import SwiftUI
import CoreBluetooth

struct SensorDataView: View {
    @ObservedObject var bleManager: BLEManager
    let peripheral: CBPeripheral
    // Replace with your actual characteristic UUIDs for temperature and humidity
    let temperatureUUID = CBUUID(string: "2A6E")
    let humidityUUID = CBUUID(string: "2A6F")
    @State private var temperature: Double? = nil
    @State private var humidity: Double? = nil

    var body: some View {
        VStack {
            if let temperature = temperature {
                SensorRow(title: "Temperature", value: temperature, unit: "°C", color: Color.blue)
            }
            if let humidity = humidity {
                SensorRow(title: "Humidity", value: humidity, unit: "%", color: Color.green)
            }
        }
        .onAppear {
            // Discover services and characteristics
            peripheral.delegate = bleManager
            peripheral.discoverServices(nil)

            // Set notify for temperature characteristic
            if let temperatureCharacteristic = findCharacteristic(with: temperatureUUID, in: peripheral) {
                bleManager.setNotifyValue(true, for: temperatureCharacteristic, of: peripheral)
                bleManager.readValue(for: temperatureCharacteristic, of: peripheral) { value in
                    if let value = value, let temp = Double(value) {
                        self.temperature = temp
                    }
                }
            }

            // Set notify for humidity characteristic
            if let humidityCharacteristic = findCharacteristic(with: humidityUUID, in: peripheral) {
                bleManager.setNotifyValue(true, for: humidityCharacteristic, of: peripheral)
                bleManager.readValue(for: humidityCharacteristic, of: peripheral) { value in
                    if let value = value, let hum = Double(value) {
                        self.humidity = hum
                    }
                }
            }
        }
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

struct SensorRow: View {
    let title: String
    let value: Double
    let unit: String
    let color: Color
    let rowHeight: CGFloat = 60 // Approximate 2 cm

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.3))
            HStack {
                Text(title)
                    .font(.headline)
                    .padding(.leading)
                Spacer()
                Text(String(format: "%.1f", value))
                    .font(.largeTitle)
                Text(unit)
                    .font(.title2)
                    .padding(.trailing)
            }
        }
        .frame(height: rowHeight)
        .padding(.horizontal)
    }
}
