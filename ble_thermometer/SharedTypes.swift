import SwiftUI
import Foundation
import SwiftData

// MARK: - Air Quality Assessment
enum AirQualityLevel: String, CaseIterable {
    case waitingForData = "Waiting for Data"
    case excellent = "Excellent"
    case good = "Good"
    case moderate = "Moderate"
    case poor = "Poor"
    case veryPoor = "Very Poor"
    
    var color: Color {
        switch self {
        case .waitingForData: return .gray
        case .excellent: return .green
        case .good: return .mint
        case .moderate: return .yellow
        case .poor: return .orange
        case .veryPoor: return .red
        }
    }
    
    var iconName: String {
        switch self {
        case .waitingForData: return "clock.circle"
        case .excellent: return "leaf.fill"
        case .good: return "checkmark.circle.fill"
        case .moderate: return "exclamationmark.triangle.fill"
        case .poor: return "xmark.circle.fill"
        case .veryPoor: return "exclamationmark.octagon.fill"
        }
    }
}

// MARK: - Data Models
@Model
final class SensorReading {
    var timestamp: Date
    var co2Value: Double
    var temperature: Double
    var humidity: Double
    var isCelsius: Bool
    
    init(timestamp: Date = Date(), co2Value: Double, temperature: Double, humidity: Double, isCelsius: Bool = true) {
        self.timestamp = timestamp
        self.co2Value = co2Value
        self.temperature = temperature
        self.humidity = humidity
        self.isCelsius = isCelsius
    }
}

// MARK: - BLE Data Structures
struct TemperatureReading {
    let temperature: Double
    let isCelsius: Bool
    
    init(temperature: Double, isCelsius: Bool = true) {
        self.temperature = temperature
        self.isCelsius = isCelsius
    }
}

@Model
final class UserSettings: ObservableObject {
    var measurementInterval: Int // in seconds
    var temperatureUnit: TemperatureUnit
    var co2AlertThreshold: Double
    var notificationsEnabled: Bool
    var userName: String
    var userEmail: String
    
    init(measurementInterval: Int = 60, 
         temperatureUnit: TemperatureUnit = .celsius, 
         co2AlertThreshold: Double = 2000,
         notificationsEnabled: Bool = true,
         userName: String = "",
         userEmail: String = "") {
        self.measurementInterval = measurementInterval
        self.temperatureUnit = temperatureUnit
        self.co2AlertThreshold = co2AlertThreshold
        self.notificationsEnabled = notificationsEnabled
        self.userName = userName
        self.userEmail = userEmail
    }
}

enum TemperatureUnit: String, CaseIterable, Codable {
    case celsius = "Celsius"
    case fahrenheit = "Fahrenheit"
    
    var symbol: String {
        switch self {
        case .celsius: return "°C"
        case .fahrenheit: return "°F"
        }
    }
}

// MARK: - BLE Decoding Functions
func decodeCO2Measurement(from hexString: String) -> Double? {
    guard let data = Data(hexString: hexString), data.count >= 2 else { return nil }
    
    // Assuming CO2 is sent as a 16-bit unsigned integer (little-endian)
    let co2Value = UInt16(data[0]) | (UInt16(data[1]) << 8)
    return Double(co2Value)
}

func decodeTemperatureMeasurement(from hexString: String) -> TemperatureReading? {
    guard let data = Data(hexString: hexString), data.count >= 5 else { return nil }
    
    // Temperature format: [unit_flag][temp_byte1][temp_byte2][temp_byte3][temp_byte4]
    // Unit flag: 0 = Celsius, 1 = Fahrenheit
    let isCelsius = data[0] == 0
    
    // Extract 32-bit temperature value (little-endian) from bytes 1-4
    let tempRaw = UInt32(data[1]) | 
                  (UInt32(data[2]) << 8) | 
                  (UInt32(data[3]) << 16) | 
                  (UInt32(data[4]) << 24)
    
    // Extract the temperature value (lower 24 bits) and convert from millidegrees
    let tempValue = Int32(tempRaw & 0x00ffffff)
    let temperature = Double(tempValue) / 1000.0
    
    return TemperatureReading(temperature: temperature, isCelsius: isCelsius)
}

func decodeHumidityMeasurement(from hexString: String) -> Double? {
    guard let data = Data(hexString: hexString), data.count >= 2 else { return nil }
    
    // Humidity is sent as a 16-bit unsigned integer (little-endian) in percent
    let humidityRaw = UInt16(data[0]) | (UInt16(data[1]) << 8)
    return Double(humidityRaw)
}

func decodeBatteryLevel(from hexString: String) -> Int? {
    guard let data = Data(hexString: hexString), data.count >= 1 else { return nil }
    
    // Battery level is typically sent as a single byte (0-100%)
    return Int(data[0])
}

// MARK: - Air Quality Functions
func getAirQualityLevel(co2: Double) -> AirQualityLevel {
    // If CO2 is 0, treat as no data - return waitingForData
    guard co2 > 0 else { return .waitingForData }
    
    switch co2 {
    case 0..<400: return .excellent
    case 400..<1000: return .good
    case 1000..<2000: return .moderate
    case 2000..<5000: return .poor
    default: return .veryPoor
    }
}

func getAirQualityRecommendation(level: AirQualityLevel, co2Value: Double = 0) -> String {
    // Show waiting message when no data is available
    if co2Value == 0 {
        return "Waiting for sensor data..."
    }
    
    switch level {
    case .waitingForData: return "Waiting for sensor data..."
    case .excellent: return "Perfect air quality! Keep it up."
    case .good: return "Good air quality. No action needed."
    case .moderate: return "Consider increasing ventilation."
    case .poor: return "Poor air quality. Open windows or increase ventilation."
    case .veryPoor: return "Very poor air quality! Immediate ventilation required."
    }
}

// MARK: - Formatting Functions
func formatCO2(_ co2: Double) -> String {
    guard co2 > 0 else { return "— PPM" }
    return String(format: "%.0f PPM", co2)
}

func formatTemperature(_ temp: Double, isCelsius: Bool) -> String {
    guard temp != 0 else { return "—" }
    let unit = isCelsius ? "°C" : "°F"
    return String(format: "%.1f%@", temp, unit)
}

func formatHumidity(_ humidity: Double) -> String {
    guard humidity > 0 else { return "—%" }
    return String(format: "%.1f%%", humidity)
}

func convertTemperature(_ temp: Double, toCelsius: Bool) -> Double {
    if toCelsius {
        return (temp - 32) * 5/9
    } else {
        return temp * 9/5 + 32
    }
}

// MARK: - BLE Encoding Functions
func encodeMeasurementInterval(_ interval: Int) -> Data {
    // Encode measurement interval as 16-bit unsigned integer (little-endian)
    var intervalValue = UInt16(interval)
    return Data(bytes: &intervalValue, count: MemoryLayout<UInt16>.size)
}

func encodeTemperatureUnit(_ isCelsius: Bool) -> Data {
    // Encode temperature unit as single byte (0 = Celsius, 1 = Fahrenheit)
    let unitValue: UInt8 = isCelsius ? 0 : 1
    return Data([unitValue])
}

func encodeCO2AlertThreshold(_ threshold: Double) -> Data {
    // Encode CO2 threshold as 16-bit unsigned integer (little-endian)
    var thresholdValue = UInt16(threshold)
    return Data(bytes: &thresholdValue, count: MemoryLayout<UInt16>.size)
}

// MARK: - Data Extensions
extension Data {
    init?(hexString: String) {
        let len = hexString.count / 2
        var data = Data(capacity: len)
        var index = hexString.startIndex
        for _ in 0..<len {
            let nextIndex = hexString.index(index, offsetBy: 2)
            if nextIndex > hexString.endIndex { return nil }
            guard let byte = UInt8(hexString[index..<nextIndex], radix: 16) else { return nil }
            data.append(byte)
            index = nextIndex
        }
        self = data
    }
    
    func hexEncodedString() -> String {
        return map { String(format: "%02hhX", $0) }.joined()
    }
}
