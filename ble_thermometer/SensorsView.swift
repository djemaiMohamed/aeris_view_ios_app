import SwiftUI
import CoreBluetooth
import Foundation

struct SensorDataView: View {
    @ObservedObject var bleManager: BLEManager
    let peripheral: CBPeripheral
    // Replace with your actual characteristic UUIDs for temperature and humidity
    let temperatureUUID = CBUUID(string: "2A1C")
    let humidityUUID = CBUUID(string: "2A6F")
    @State private var temperature: Double? = nil
    @State private var humidity: Double? = nil
    @State private var lastTemperatureUpdate: Date?
    @State private var lastHumidityUpdate: Date?
    @AppStorage("temperatureUnit") private var temperatureUnit: SettingsView.TemperatureUnit = .celsius

    private func formattedDate(from date: Date?) -> String {
        guard let date = date else { return "Never" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm:ss a"
        return formatter.string(from: date)
    }

    // Function to convert temperature based on user preference
    private func getTemperature(temperatureInCelsius: Double?) -> Double? {
        guard let temperatureInCelsius = temperatureInCelsius else { return nil }
        if temperatureUnit == .fahrenheit {
            return (temperatureInCelsius * 9/5) + 32
        } else {
            return temperatureInCelsius
        }
    }

    // Function to get the correct unit string
    private func getTemperatureUnit() -> String {
        return temperatureUnit == .fahrenheit ? "°F" : "°C"
    }

    var body: some View {
        VStack {
            // Sensor data blocks at the top
            if let temperatureCelsius = temperature {
                let temperatureToDisplay = getTemperature(temperatureInCelsius: temperatureCelsius)
                VStack {
                    SensorRow(title: "Temperature", value: temperatureToDisplay ?? 0.0, unit: getTemperatureUnit(), color: Color.blue, lastUpdate: lastTemperatureUpdate)
                }
            }
            if let humidity = humidity {
                VStack {
                    SensorRow(title: "Humidity", value: humidity, unit: "%", color: Color.green, lastUpdate: lastHumidityUpdate)
                }
            }

            Spacer() // Push sensor data to the top

        }
        .onAppear {
            // Discover services and characteristics
            peripheral.delegate = bleManager
            print("1")
            peripheral.discoverServices(nil)
            print("2")

            // Set notify for temperature characteristic
            if let temperatureCharacteristic = findCharacteristic(with: temperatureUUID, in: peripheral) {
                bleManager.setNotifyValue(true, for: temperatureCharacteristic, of: peripheral)
                bleManager.readValue(for: temperatureCharacteristic, of: peripheral) { value in
                    self.temperature = decodeTemperatureMeasurement(from: value)?.temperature
                    self.lastTemperatureUpdate = Date()
                }
            }

            // Set notify for humidity characteristic
            if let humidityCharacteristic = findCharacteristic(with: humidityUUID, in: peripheral) {
                bleManager.setNotifyValue(true, for: humidityCharacteristic, of: peripheral)
                bleManager.readValue(for: humidityCharacteristic, of: peripheral) { value in
                    self.humidity = decodeHumidityMeasurement(from: value)
                    self.lastHumidityUpdate = Date()
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
    let rowHeight: CGFloat = 75 // Approximate 2 cm
    let lastUpdate: Date?

    private func formattedDate(from date: Date?) -> String {
        guard let date = date else { return "Never" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm:ss a"
        return formatter.string(from: date)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.3))
            VStack {
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
                HStack {
                    Text("Last updated: \(formattedDate(from: lastUpdate))")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .padding(.leading) // Add leading padding
                    Spacer() // Push the text to the left
                }
            }
        }
        .frame(height: rowHeight)
        .padding(.horizontal)
    }
}
