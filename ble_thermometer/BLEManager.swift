import CoreBluetooth
import SwiftData
import UserNotifications
import SwiftUI
import Foundation

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
    @Published var calibrationInProgress: Bool = false
    @Published var calibrationFinished: Bool = false
    @Published var calibrationStatusMessage: String = ""
    
    // MARK: - BLE Core Properties
    var centralManager: CBCentralManager!
    var serviceDiscoveryCompletion: (([CBService]) -> Void)?
    var readValueCompletion: [CBUUID: (String) -> Void] = [:]
    var characteristicNameCache: [CBUUID: String] = [:]
    var modelContext: ModelContext?
    var userSettings: UserSettings?
    
    // MARK: - Notification Properties
    private var lastNotificationTime: Date?
    private var co2ValueWasBelowThreshold: Bool = true // Added
    private let notificationCooldownPeriod: TimeInterval = 300 // 5 minutes

    // Replace these UUIDs with your actual service and characteristic UUIDs
    let targetServiceUUID = CBUUID(string: "1809")
    let batteryServiceUUID = CBUUID(string: "180F") // Battery Service
    let co2CharUUID = CBUUID(string: "30171109-f957-45e4-81ef-f0c8e64116ea")
    let tempCharUUID = CBUUID(string: "2A1C")
    let humCharUUID = CBUUID(string: "2A6F")
    let measurementIntervalUUID = CBUUID(string: "2A21")
    let tempUnitCharUUID = CBUUID(string: "123c7dfe-ede3-4889-84c5-c0382a32df05") // Temperature Unit Characteristic
    let batteryLevelUUID = CBUUID(string: "2A19") // Battery Level Characteristic
    let calibrationCharUUID = CBUUID(string: "bf40623a-300b-4793-b4ad-7a9970f6732d") // CO2 Calibration Characteristic

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
    characteristicNameCache[calibrationCharUUID] = "CO2 Calibration"
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
        // Clean up completion handlers to prevent memory leaks
        readValueCompletion.removeAll()
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
        peripheral.discoverServices(nil) // discover all services
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
        _ = advertisedServices.contains(targetServiceUUID) // Check but don't store unused value
        
        // Log all discovered devices for debugging
        let deviceName = peripheral.name ?? "Unknown Device"
        let serviceInfo = advertisedServices.isEmpty ? "No services advertised" : "Services: \(advertisedServices.map { $0.uuidString }.joined(separator: ", "))"
        print("🔍 Discovered: \(deviceName) | RSSI: \(RSSI) | \(serviceInfo)")
        
        // Check if this is an Air Quality device using helper function
        let isAirQuality = isAirQualityDevice(peripheral)
        
        // Add device to list with size limit to prevent memory issues
        if isAirQuality && !peripherals.contains(peripheral) {
            // Limit the number of peripherals to prevent memory bloat
            if peripherals.count >= 50 {
                peripherals.removeFirst(10) // Remove oldest 10 when limit reached
            }
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
            peripheral.discoverServices(nil) // discover all services to find custom calibration characteristic
            print("🔗 Connected to \(peripheral.name ?? "Unknown Device")")
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async {
            self.connectedPeripheral = nil
            self.isConnecting = false
            self.connectionStatus = "Disconnected"
            
            // Clean up completion handlers for this peripheral
            self.readValueCompletion.removeAll()
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
                characteristic.uuid == batteryLevelUUID ||
                characteristic.uuid == calibrationCharUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }

            if characteristic.uuid == measurementIntervalUUID {
                // Read the measurement interval characteristic
                peripheral.readValue(for: characteristic)
            }
            
            if characteristic.uuid == tempUnitCharUUID {
                // Read the temperature unit characteristic
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let stringValue = data.hexEncodedString()

        // Assume bonding is complete when value is received
        isBonded = true

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
        case tempUnitCharUUID:
            print("Temperature unit updated: \(stringValue)")
            if let tempUnit = decodeTemperatureUnit(from: stringValue) {
                isTempCelsius = (tempUnit == 0)
                print("Temperature unit set to \(isTempCelsius ? "Celsius" : "Fahrenheit")")
            } else {
                print("Failed to decode temperature unit from: \(stringValue)")
            }
        case calibrationCharUUID:
            // Device sends 0x01 when calibration finishes
            if data.count >= 1, data[0] == 0x01 {
                DispatchQueue.main.async {
                    self.calibrationInProgress = false
                    self.calibrationFinished = true
                    self.calibrationStatusMessage = "Calibration finished."
                }
                print("✅ Calibration finished notification received")
            } else {
                print("Calibration characteristic updated: \(stringValue)")
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
    private var lastSaveTime: Date = Date()
    private let minimumSaveInterval: TimeInterval = 60 // Save at most once per minute
    
    private func saveSensorReading() {
        guard let context = modelContext else { return }
        
        // Throttle database saves to improve performance
        let now = Date()
        guard now.timeIntervalSince(lastSaveTime) >= minimumSaveInterval else { return }
        
        let reading = SensorReading(
            co2Value: co2Value,
            temperature: tempValue,
            humidity: humValue,
            isCelsius: isTempCelsius
        )
        
        context.insert(reading)
        
        do {
            try context.save()
            lastSaveTime = now
            
            // Clean up old readings to prevent database bloat
            cleanupOldReadings(context: context)
        } catch {
            print("Failed to save sensor reading: \(error)")
        }
    }
    
    private func cleanupOldReadings(context: ModelContext) {
        // Keep only readings from the last 30 days
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        
        let request = FetchDescriptor<SensorReading>(
            predicate: #Predicate<SensorReading> { reading in
                reading.timestamp < cutoffDate
            }
        )
        
        do {
            let oldReadings = try context.fetch(request)
            if !oldReadings.isEmpty {
                for reading in oldReadings {
                    context.delete(reading)
                }
                print("Cleaned up \(oldReadings.count) old readings")
            }
        } catch {
            print("Failed to cleanup old readings: \(error)")
        }
    }
    
    // MARK: - Air Quality Monitoring
    private func updateAirQualityLevel() {
        let newLevel = getAirQualityLevel(co2: co2Value)
        
        // Check if level has changed
        if airQualityLevel != newLevel {
            // previousAirQualityLevel = airQualityLevel // Removed
            airQualityLevel = newLevel
            // currentLevelStartTime = Date() // Removed
            print("Air quality level changed to: \(newLevel.rawValue)")
        }
        
        lastUpdateTime = Date()
    }
    
    private func handleAirQualityNotifications() {
        // Check if user has notifications enabled
        guard let settings = userSettings, settings.notificationsEnabled else { return }
        
        let co2Threshold = settings.co2AlertThreshold
        let timeSinceLastNotification = lastNotificationTime?.timeIntervalSinceNow ?? -(notificationCooldownPeriod + 1) // Ensure first notification can pass

        if co2Value > co2Threshold && co2ValueWasBelowThreshold && abs(timeSinceLastNotification) > notificationCooldownPeriod {
            scheduleAirQualityNotification(currentCO2: co2Value, threshold: co2Threshold)
            co2ValueWasBelowThreshold = false
            // lastNotificationTime will be set in scheduleAirQualityNotification upon success
        } else if co2Value <= co2Threshold {
            co2ValueWasBelowThreshold = true // Reset when value drops below or equals threshold
        }
    }
    
    private func scheduleAirQualityNotification(currentCO2: Double, threshold: Double) {
        let content = UNMutableNotificationContent()
        content.title = "CO2 Alert"
        
        content.body = "CO2 level is \(Int(currentCO2)) PPM, exceeding the threshold of \(Int(threshold)) PPM. Consider increasing ventilation."
        
        content.sound = UNNotificationSound.default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling CO2 alert notification: \(error)")
            } else {
                print("CO2 alert notification scheduled. Current: \(Int(currentCO2)) PPM, Threshold: \(Int(threshold)) PPM")
                self.lastNotificationTime = Date()
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private func decodeMeasurementInterval(from hexString: String) -> Int? {
        // Measurement interval decoding
        guard let data = Data(hexString: hexString) else { return nil }
        if data.count >= 2 {
            let value = UInt16(data[0]) | (UInt16(data[1]) << 8)
            return Int(value)
        }
        return nil
    }
    
    private func decodeTemperatureUnit(from hexString: String) -> UInt8? {
        // Temperature unit decoding (1 byte: 0 = Celsius, 1 = Fahrenheit)
        guard let data = Data(hexString: hexString), data.count >= 1 else { return nil }
        return data[0]
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
    
    /// Writes temperature unit to the connected BLE device
    func writeTemperatureUnit(_ isCelsius: Bool) {
        guard let peripheral = connectedPeripheral,
              peripheral.state == .connected else {
            print("No connected peripheral to write temperature unit")
            return
        }
        
        // Find the temperature unit characteristic
        guard let services = peripheral.services else { return }
        for service in services {
            guard let characteristics = service.characteristics else { continue }
            for characteristic in characteristics {
                if characteristic.uuid == tempUnitCharUUID {
                    // Convert temperature unit to data (1 byte: 0 = Celsius, 1 = Fahrenheit)
                    let unitValue: UInt8 = isCelsius ? 0 : 1
                    let data = Data([unitValue])
                    
                    writeValue(for: characteristic, of: peripheral, value: data)
                    print("📝 Writing temperature unit: \(isCelsius ? "Celsius" : "Fahrenheit")")
                    return
                }
            }
        }
        print("❌ Temperature unit characteristic not found")
    }

    /// Starts CO2 calibration by writing the reference PPM to the calibration characteristic
    func startCO2Calibration(ppm: Int) {
        guard let peripheral = connectedPeripheral, peripheral.state == .connected else {
            print("No connected peripheral to start calibration")
            return
        }
        calibrationFinished = false
        calibrationInProgress = true
        calibrationStatusMessage = "Calibration started. Keep device outdoors in fresh air."
        // Find characteristic
        guard let services = peripheral.services else {
            print("No services discovered yet")
            return
        }
        for service in services {
            guard let characteristics = service.characteristics else { continue }
            for characteristic in characteristics where characteristic.uuid == calibrationCharUUID {
                var value = UInt16(ppm)
                let data = Data(bytes: &value, count: MemoryLayout<UInt16>.size)
                writeValue(for: characteristic, of: peripheral, value: data)
                print("🧭 Starting calibration with reference \(ppm) PPM")
                return
            }
        }
        print("❌ Calibration characteristic not found")
        calibrationStatusMessage = "Calibration characteristic not found."
        calibrationInProgress = false
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
    
    // MARK: - Memory Management
    
    /// Cleans up resources to improve performance and reduce memory usage
    func performMemoryCleanup() {
        // Clear completion handlers
        readValueCompletion.removeAll()
        
        // Limit peripherals array size
        if peripherals.count > 20 {
            let airQualityDevices = peripherals.filter { isAirQualityDevice($0) }
            let otherDevices = peripherals.filter { !isAirQualityDevice($0) }
            
            // Keep all Air Quality devices but limit others
            peripherals = airQualityDevices + Array(otherDevices.prefix(10))
            print("🧹 Cleaned up peripherals array: \(peripherals.count) devices remaining")
        }
        
        // Trigger old readings cleanup if we have context
        if let context = modelContext {
            cleanupOldReadings(context: context)
        }
    }
}
