import SwiftUI
import Foundation

/// Decodes the raw data from a BLE Temperature Measurement characteristic into a temperature value.
/// - Parameter hexString: The hexadecimal string received from the BLE characteristic.
/// - Returns: A tuple containing the temperature value and a boolean indicating whether the temperature is in Celsius (`true`) or Fahrenheit (`false`).
func decodeTemperatureMeasurement(from hexString: String) -> (temperature: Double, isCelsius: Bool)? {
    // Convert hex string to Data
    guard let data = Data(hexString: hexString) else {
        print("Invalid hex string")
        return nil
    }

    // Ensure the data is at least 3 bytes long (Flags byte + at least 2 bytes for temperature value)
    guard data.count >= 3 else {
        print("Invalid data length")
        return nil
    }

    // Extract the Flags byte
    let flags = data[0]

    // Determine the temperature unit from the Flags byte
    let isCelsius = (flags & 0x01) == 0

    // Extract the Temperature Measurement Value bytes (little-endian format)
    let tempData = data.subdata(in: 1..<3)
    let tempValue = tempData.withUnsafeBytes { $0.load(as: Int16.self) }

    // Convert the temperature value to the appropriate unit
    let temperature = Double(tempValue) / 1000.0

    return (temperature, isCelsius)
}

/// Decodes the raw data from a BLE Humidity characteristic into a humidity value.
/// - Parameter hexString: The hexadecimal string received from the BLE characteristic.
/// - Returns: The humidity value as a percentage, or nil if decoding fails.
func decodeHumidityMeasurement(from hexString: String) -> Double? {
    // Convert hex string to Data
    guard let data = Data(hexString: hexString) else {
        print("Invalid hex string")
        return nil
    }

    // Ensure the data is exactly 2 bytes long
    guard data.count == 2 else {
        print("Invalid data length")
        return nil
    }

    // Convert the two bytes into a UInt16 value (little-endian format)
    let humidityValue = data.withUnsafeBytes { $0.load(as: UInt16.self) }

    let humidity = Double(humidityValue)

    return humidity
}

extension Data {
    /// Initializes Data from a hexadecimal string representation.
    /// - Parameter hexString: The hexadecimal string.
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
}
//
//  utils.swift
//  ble_thermometer
//
//  Created by Mohamed Djemai on 2025-04-01.
//

