import CoreBluetooth
import SwiftData
import UserNotifications
import SwiftUI

class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    // MARK: - Published Properties
    @Published var isBluetoothEnabled = false // Tracks Bluetooth state
    @Published var peripherals: [CBPeripheral] = [] // List of discovered peripherals
    // bondedPeripheral is used to reconnect to previously bonded devices
    @Published var bondedPeripheral: CBPeripheral? // Previously bonded peripheral
    @Published var connectedPeripheral: CBPeripheral? // Currently connected peripheral
    @Published var isBonded: Bool = false // Tracks bonding status
    @Published var co2Value: Double = 0.0 // Last CO2 value received (PPM)
    @Published var tempValue: Double = 0.0 // Last temperature value received (degrees)
    @Published var humValue: Double = 0.0 // Last humidity value received (percentage)
    @Published var measurementInterval: Int = 30 // Measurement interval in seconds
    @Published var isTempCelsius: Bool = true // Temperature unit flag
    @Published var isConnecting: Bool = false
    @Published var connectionStatus: String = "Disconnected"
    @Published var airQualityLevel: AirQualityLevel = .excellent
    @Published var lastUpdateTime: Date = Date()
    @Published var batteryLevel: Int = 0 // Battery level percentage (0-100)
    
    // MARK: - BLE Core Properties
    var centralManager: CBCentralManager!
    var serviceDiscoveryCompletion: (([CBService]) -> Void)?
    var readValueCompletion: [CBUUID: (String) -> Void] = [:]
    var characteristicNameCache: [CBUUID: String] = [:]
    var modelContext: ModelContext?
    var userSettings: UserSettings?
    
    // MARK: - Notification Properties
    private var lastNotificationTime: Date?
    private var currentLevelStartTime: Date?
    private var previousAirQualityLevel: AirQualityLevel?
    private let notificationCooldownPeriod: TimeInterval = 300 // 5 minutes
    private let levelChangeThreshold: TimeInterval = 300 // 5 minutes

    // Replace these UUIDs with your actual service and characteristic UUIDs
    let targetServiceUUID = CBUUID(string: "1809")
    let batteryServiceUUID = CBUUID(string: "180F") // Battery Service
    let co2CharUUID = CBUUID(string: "30171109-f957-45e4-81ef-f0c8e64116ea")
    let tempCharUUID = CBUUID(string: "2A1C")
    let humCharUUID = CBUUID(string: "2A6F")
    let measurementIntervalUUID = CBUUID(string: "2A21")
    let batteryLevelUUID = CBUUID(string: "2A19") // Battery Level Characteristic

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        loadCharacteristicNames()
        requestNotificationPermission()
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    func setUserSettings(_ settings: UserSettings) {
        self.userSettings = settings
    }
    
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    // Load characteristic names from YAML file
    func loadCharacteristicNames() {
        // For now, we'll populate with some common characteristic names
        characteristicNameCache[CBUUID(string: "2A1C")] = "Temperature Measurement"
        characteristicNameCache[CBUUID(string: "2A6F")] = "Humidity"
        characteristicNameCache[co2CharUUID] = "CO2 Measurement"
        characteristicNameCache[CBUUID(string: "2A19")] = "Battery Level"
        characteristicNameCache[CBUUID(string: "2A00")] = "Device Name"
    }

    func getCharacteristicName(uuid: CBUUID) -> String {
        return characteristicNameCache[uuid] ?? "Unknown Characteristic"
    }

    // MARK: - Air Quality Device Detection
    
    /// Checks if a peripheral is an Air Quality sensor device
    /// - Parameter peripheral: The BLE peripheral to check
    /// - Returns: True if the device name starts with "Air Quality"
    func isAirQualityDevice(_ peripheral: CBPeripheral) -> Bool {
        guard let name = peripheral.name else { return false }
        return name.hasPrefix("Air Quality")
    }

    // MARK: - Scanning
    func startScan() {
        guard isBluetoothEnabled else {
            print("Bluetooth is not enabled")
            return
        }
        
        // Clear previous peripherals when starting a new scan
        peripherals.removeAll()
        
        // Scan for all peripherals, not just specific services to discover more devices
        centralManager.scanForPeripherals(withServices: nil, options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        print("🔍 Scanning started - prioritizing Air Quality devices")
        print("📡 Looking for devices with names starting with 'Air Quality'")
    }

    func stopScan() {
        centralManager.stopScan()
        print("Scanning stopped")
    }

    // MARK: - Connection
    func connect(peripheral: CBPeripheral) {
        isConnecting = true
        connectionStatus = "Connecting..."
        peripheral.delegate = self
        centralManager.connect(peripheral, options: [CBConnectPeripheralOptionNotifyOnConnectionKey: true])
    }

    func disconnect(peripheral: CBPeripheral) {
        centralManager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - Discovery and Notification Setup
    func discoverServices(for peripheral: CBPeripheral, completion: @escaping ([CBService]) -> Void) {
        peripheral.delegate = self
        serviceDiscoveryCompletion = completion
        peripheral.discoverServices([targetServiceUUID, batteryServiceUUID])
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic, of peripheral: CBPeripheral) {
        if peripheral.state == .connected {
            peripheral.setNotifyValue(enabled, for: characteristic)
        } else {
            print("Peripheral not connected. Can't enable notifications.")
        }
    }

    func writeValue(for characteristic: CBCharacteristic, of peripheral: CBPeripheral, value: Data) {
        if peripheral.state == .connected {
            peripheral.writeValue(value, for: characteristic, type: .withResponse)
        } else {
            print("Peripheral not connected. Can't write value.")
        }
    }

    // MARK: - CBCentralManagerDelegate
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            isBluetoothEnabled = true
            // Auto reconnect to previously bonded devices
            reconnectToBondedDevice(with: central)
        } else {
            isBluetoothEnabled = false
            print("Bluetooth is not powered on")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Check if device advertises our target service
        let advertisedServices = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let hasTargetService = advertisedServices.contains(targetServiceUUID)
        
        // Log all discovered devices for debugging
        let deviceName = peripheral.name ?? "Unknown Device"
        let serviceInfo = advertisedServices.isEmpty ? "No services advertised" : "Services: \(advertisedServices.map { $0.uuidString }.joined(separator: ", "))"
        print("🔍 Discovered: \(deviceName) | RSSI: \(RSSI) | \(serviceInfo)")
        
        // Check if this is an Air Quality device using helper function
        let isAirQuality = isAirQualityDevice(peripheral)
        
        // Add device to list
        if isAirQuality && !peripherals.contains(peripheral) {
            // Insert Air Quality devices at the beginning for priority
            peripherals.append(peripheral)
            print("Air Quality device added: \(deviceName)")
        } else {
            print("Skipped device")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            self.connectedPeripheral = peripheral
            self.isConnecting = false
            self.connectionStatus = "Connected"
            peripheral.discoverServices([self.targetServiceUUID])
            print("🔗 Connected to \(peripheral.name ?? "Unknown Device")")
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async {
            self.connectedPeripheral = nil
            self.isConnecting = false
            self.connectionStatus = "Disconnected"
        }
    }

    // MARK: - CBPeripheralDelegate
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func reconnectToBondedDevice(with centralManager: CBCentralManager) {
        if let uuidString = UserDefaults.standard.string(forKey: "bondedDeviceUUID"),
        let uuid = UUID(uuidString: uuidString) {

            let peripherals = centralManager.retrievePeripherals(withIdentifiers: [uuid])
            if let peripheral = peripherals.first {
                isBonded = true
                //startScan()
                print("🔗 Reconnecting to bonded device: \(peripheral.name ?? "Unknown")")
                self.peripherals.append(contentsOf: peripherals)
                connect(peripheral: peripheral)
            } else {
                // Fallback: scan and match by UUID or name prefix
                centralManager.scanForPeripherals(withServices: nil, options: nil)
            }
        }
    }

    // MARK: - Device Management
    func forgetBondedDevice() {
        UserDefaults.standard.removeObject(forKey: "bondedDeviceUUID")
        isBonded = false
        bondedPeripheral = nil
        // if connectedPeripheral is not nil, disconnect it
        guard let connectedPeripheral = connectedPeripheral else {
            print("No connected peripheral to forget.")
            return
        }
        disconnect(peripheral: connectedPeripheral)

        print("🗑️ Forgotten bonded device.")
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            // Enable notifications for relevant characteristics
            if characteristic.uuid == co2CharUUID ||
                characteristic.uuid == tempCharUUID ||
                characteristic.uuid == humCharUUID ||
                characteristic.uuid == batteryLevelUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }

            if characteristic.uuid == measurementIntervalUUID {
                // Read the measurement interval characteristic
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let stringValue = data.hexEncodedString()

        // Assume bonding is complete when value is received
        isBonded = true
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "bondedDeviceUUID")

        // Parse and assign characteristic values using proper decoding functions
        switch characteristic.uuid {
        case co2CharUUID:
            if let decodedValue = decodeCO2Measurement(from: stringValue) {
                co2Value = decodedValue
                print("CO2 decoded: \(decodedValue) PPM")
            } else {
                print("Failed to decode CO2 value from: \(stringValue)")
            }
        case tempCharUUID:
            if let decodedTemp = decodeTemperatureMeasurement(from: stringValue) {
                tempValue = decodedTemp.temperature
                isTempCelsius = decodedTemp.isCelsius
                print("Temperature decoded: \(decodedTemp.temperature)° \(decodedTemp.isCelsius ? "C" : "F")")
            } else {
                print("Failed to decode temperature value from: \(stringValue)")
            }
        case humCharUUID:
            if let decodedValue = decodeHumidityMeasurement(from: stringValue) {
                humValue = decodedValue
                print("Humidity decoded: \(decodedValue)%")
            } else {
                print("Failed to decode humidity value from: \(stringValue)")
            }
        case batteryLevelUUID:
            if let decodedValue = decodeBatteryLevel(from: stringValue) {
                batteryLevel = decodedValue
                print("Battery level decoded: \(decodedValue)%")
            } else {
                print("Failed to decode battery level from: \(stringValue)")
            }
        case measurementIntervalUUID:
            print("Measurement interval updated: \(stringValue)")
            if let interval = decodeMeasurementInterval(from: stringValue) {
                measurementInterval = interval
                print("Measurement interval set to \(interval) seconds")
                
                // Update UserSettings if available
                if let settings = userSettings {
                    settings.measurementInterval = interval
                    // Save the context if available
                    if let context = modelContext {
                        try? context.save()
                    }
                    print("📱 UserSettings measurement interval updated to \(interval) seconds")
                }
            } else {
                print("Failed to decode measurement interval from: \(stringValue)")
            }
        default:
            break
        }
        
        // Update air quality level based on CO2 values
        updateAirQualityLevel()
        
        // Save sensor reading to database
        saveSensorReading()
        
        // Handle notifications for air quality changes
        handleAirQualityNotifications()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Write failed: \(error)")
        } else {
            print("Write successful")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error updating notification state: \(error.localizedDescription)")
        } else {
            print("Notification state updated for \(characteristic.uuid)")
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "bondedDeviceUUID")
            isBonded = true
            bondedPeripheral = peripheral
            print("🔗 Bonded to device: \(peripheral.name ?? "Unknown")")
        }
    }

    // MARK: - Data Management
    private func saveSensorReading() {
        guard let context = modelContext else { return }
        
        let reading = SensorReading(
            co2Value: co2Value,
            temperature: tempValue,
            humidity: humValue,
            isCelsius: isTempCelsius
        )
        
        context.insert(reading)
        
        do {
            try context.save()
        } catch {
            print("Failed to save sensor reading: \(error)")
        }
    }
    
    // MARK: - Air Quality Monitoring
    private func updateAirQualityLevel() {
        let newLevel = getAirQualityLevel(co2: co2Value)
        
        // Check if level has changed
        if airQualityLevel != newLevel {
            previousAirQualityLevel = airQualityLevel
            airQualityLevel = newLevel
            currentLevelStartTime = Date()
            print("Air quality level changed to: \(newLevel.rawValue)")
        } else {
            airQualityLevel = newLevel
        }
        
        lastUpdateTime = Date()
    }
    
    private func handleAirQualityNotifications() {
        // Check if user has notifications enabled
        guard let settings = userSettings, settings.notificationsEnabled else { return }
        
        // Check if we have a level change and enough time has passed
        guard let levelStartTime = currentLevelStartTime else { return }
        
        let timeSinceLastNotification = lastNotificationTime?.timeIntervalSinceNow ?? -notificationCooldownPeriod
        let timeSinceLevelChange = Date().timeIntervalSince(levelStartTime)
        
        // Send notification if level has been stable for 5+ minutes and cooldown has passed
        if timeSinceLevelChange > levelChangeThreshold &&
           abs(timeSinceLastNotification) > notificationCooldownPeriod {
            scheduleAirQualityNotification()
        }
    }
    
    private func scheduleAirQualityNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Air Quality Changed"
        
        // Customize message based on level
        switch airQualityLevel {
        case .excellent:
            content.body = "Air quality is now excellent (\(Int(co2Value)) PPM). Great air quality!"
        case .good:
            content.body = "Air quality is now good (\(Int(co2Value)) PPM). Nice air quality!"
        case .moderate:
            content.body = "Air quality is now moderate (\(Int(co2Value)) PPM). Consider increasing ventilation."
        case .poor:
            content.body = "Air quality is now poor (\(Int(co2Value)) PPM). Open windows or increase ventilation."
        case .veryPoor:
            content.body = "Air quality is now very poor (\(Int(co2Value)) PPM). Immediate ventilation required!"
        }
        
        content.sound = UNNotificationSound.default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling notification: \(error)")
            } else {
                print("Air quality change notification scheduled: \(self.airQualityLevel.rawValue)")
                self.lastNotificationTime = Date()
            }
        }
    }
    
    // MARK: - Helper Functions
    private func getAirQualityLevel(co2: Double) -> AirQualityLevel {
        switch co2 {
        case 0..<400:
            return .excellent
        case 400..<1000:
            return .good
        case 1000..<2000:
            return .moderate
        case 2000..<5000:
            return .poor
        default:
            return .veryPoor
        }
    }
    
    private func decodeCO2Measurement(from hexString: String) -> Double? {
        // Simple hex to decimal conversion for CO2 values
        // Adjust this based on your device's data format
        guard let data = Data(hexString: hexString) else { return nil }
        if data.count >= 2 {
            let value = UInt16(data[0]) | (UInt16(data[1]) << 8)
            return Double(value)
        }
        return nil
    }
    
    private func decodeTemperatureMeasurement(from hexString: String) -> (temperature: Double, isCelsius: Bool)? {
        // Decode hex string into Data
        guard let data = Data(hexString: hexString) else { return nil }
        guard data.count >= 5 else { return nil }

        let flags = data[0]
        let isCelsius = (flags & 0x01) == 0

        // Extract 24-bit signed integer from data[1...3]
        let rawValue = Int32(UInt32(data[1]) | (UInt32(data[2]) << 8) | (UInt32(data[3]) << 16))
        
        // Sign-extend the 24-bit value to 32-bit
        let signedValue = (rawValue << 8) >> 8
        
        // Apply exponent -3
        let temperature = Double(signedValue) / 1000.0

        return (temperature, isCelsius)
    }
    
    private func decodeHumidityMeasurement(from hexString: String) -> Double? {
        // Humidity measurement decoding
        guard let data = Data(hexString: hexString) else { return nil }
        if data.count >= 2 {
            let value = UInt16(data[0]) | (UInt16(data[1]) << 8)
            return Double(value)
        }
        return nil
    }

    // decode measurement interval
    private func decodeMeasurementInterval(from hexString: String) -> Int? {
        // Measurement interval decoding
        guard let data = Data(hexString: hexString) else { return nil }
        if data.count >= 2 {
            let value = UInt16(data[0]) | (UInt16(data[1]) << 8)
            return Int(value)
        }
        return nil
    }
    
    /// Automatically connects to the first Air Quality device found
    /// - Returns: True if an Air Quality device was found and connection initiated
    func connectToFirstAirQualityDevice() -> Bool {
        guard let airQualityDevice = peripherals.first(where: { isAirQualityDevice($0) }) else {
            print("❌ No Air Quality devices found in scan results")
            return false
        }
        
        print("🎯 Auto-connecting to Air Quality device: \(airQualityDevice.name ?? "Unknown")")
        connect(peripheral: airQualityDevice)
        return true
    }
    
    /// Gets all Air Quality devices from the current scan results
    /// - Returns: Array of Air Quality device peripherals
    func getAirQualityDevices() -> [CBPeripheral] {
        return peripherals.filter { isAirQualityDevice($0) }
    }
    
    // MARK: - Helper Functions
    
    /// Writes measurement interval to the connected BLE device
    func writeMeasurementInterval(_ interval: Int) {
        guard let peripheral = connectedPeripheral,
              peripheral.state == .connected else {
            print("No connected peripheral to write measurement interval")
            return
        }
        
        // Find the measurement interval characteristic
        guard let services = peripheral.services else { return }
        for service in services {
            guard let characteristics = service.characteristics else { continue }
            for characteristic in characteristics {
                if characteristic.uuid == measurementIntervalUUID {
                    // Convert interval to data (little-endian 16-bit)
                    var intervalValue = UInt16(interval)
                    let data = Data(bytes: &intervalValue, count: MemoryLayout<UInt16>.size)
                    
                    writeValue(for: characteristic, of: peripheral, value: data)
                    print("📝 Writing measurement interval: \(interval) seconds")
                    return
                }
            }
        }
        print("❌ Measurement interval characteristic not found")
    }
    
    // MARK: - Computed Properties for User Preferences
    var displayTemperature: Double {
        guard let settings = userSettings else { return tempValue }
        
        // Convert temperature based on user's preferred unit
        if settings.temperatureUnit == .celsius {
            return isTempCelsius ? tempValue : convertTemperature(tempValue, toCelsius: true)
        } else {
            return isTempCelsius ? convertTemperature(tempValue, toCelsius: false) : tempValue
        }
    }
    
    var displayTemperatureUnit: TemperatureUnit {
        return userSettings?.temperatureUnit ?? .celsius
    }
    
    // MARK: - Testing/Debug Methods
    
    /// Simulates a CO2 level change for testing notifications
    /// - Parameter co2Level: The CO2 value to simulate
    func simulateCO2Reading(_ co2Level: Double) {
        co2Value = co2Level
        updateAirQualityLevel()
        handleAirQualityNotifications()
        print("🧪 Simulated CO2 reading: \(co2Level) PPM - Level: \(airQualityLevel.rawValue)")
    }
}
