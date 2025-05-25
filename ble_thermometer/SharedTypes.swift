import SwiftUI
import Foundation
import SwiftData

// MARK: - Air Quality Assessment
enum AirQualityLevel: String, CaseIterable {
    case excellent = "Excellent"
    case good = "Good"
    case moderate = "Moderate"
    case poor = "Poor"
    case veryPoor = "Very Poor"
    
    var color: Color {
        switch self {
        case .excellent: return .green
        case .good: return .mint
        case .moderate: return .yellow
        case .poor: return .orange
        case .veryPoor: return .red
        }
    }
    
    var iconName: String {
        switch self {
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
    let co2Value = data.withUnsafeBytes { $0.load(as: UInt16.self) }
    return Double(co2Value)
}

func decodeTemperatureMeasurement(from hexString: String) -> (temperature: Double, isCelsius: Bool)? {
    guard let data = Data(hexString: hexString), data.count >= 3 else { return nil }
    let flags = data[0]
    let isCelsius = (flags & 0x01) == 0
    let tempData = data.subdata(in: 1..<3)
    let tempValue = tempData.withUnsafeBytes { $0.load(as: Int16.self) }
    let temperature = Double(tempValue) / 1000.0
    return (temperature, isCelsius)
}

func decodeHumidityMeasurement(from hexString: String) -> Double? {
    guard let data = Data(hexString: hexString), data.count == 2 else { return nil }
    let humidityValue = data.withUnsafeBytes { $0.load(as: UInt16.self) }
    return Double(humidityValue)
}

// MARK: - Air Quality Functions
func getAirQualityLevel(co2: Double) -> AirQualityLevel {
    switch co2 {
    case 0..<400: return .excellent
    case 400..<1000: return .good
    case 1000..<2000: return .moderate
    case 2000..<5000: return .poor
    default: return .veryPoor
    }
}

func getAirQualityRecommendation(level: AirQualityLevel) -> String {
    switch level {
    case .excellent: return "Perfect air quality! Keep it up."
    case .good: return "Good air quality. No action needed."
    case .moderate: return "Consider increasing ventilation."
    case .poor: return "Poor air quality. Open windows or increase ventilation."
    case .veryPoor: return "Very poor air quality! Immediate ventilation required."
    }
}

// MARK: - Formatting Functions
func formatCO2(_ co2: Double) -> String {
    return String(format: "%.0f PPM", co2)
}

func formatTemperature(_ temp: Double, isCelsius: Bool) -> String {
    let unit = isCelsius ? "°C" : "°F"
    return String(format: "%.1f%@", temp, unit)
}

func formatHumidity(_ humidity: Double) -> String {
    return String(format: "%.1f%%", humidity)
}

func convertTemperature(_ temp: Double, toCelsius: Bool) -> Double {
    if toCelsius {
        return (temp - 32) * 5/9
    } else {
        return temp * 9/5 + 32
    }
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
