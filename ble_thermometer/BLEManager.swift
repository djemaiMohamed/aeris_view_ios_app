import CoreBluetooth
import SwiftData
import UserNotifications
import SwiftUI
import Foundation

class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // Per-device state for multi-device support
    struct DeviceSnapshot {
        var co2: Double = 0
        var temp: Double = 0
        var hum: Double = 0
        var isCelsius: Bool = true
        var battery: Int = 0
    }

    // MARK: - Published Properties
    @Published var isBluetoothEnabled = false // Tracks Bluetooth state
    @Published var peripherals: [CBPeripheral] = [] // List of discovered peripherals
    // bondedPeripheral is used to reconnect to previously bonded devices
    @Published var bondedPeripheral: CBPeripheral? // Previously bonded peripheral
    @Published var connectedPeripheral: CBPeripheral? // Currently connected peripheral
    // Multi-device support
    @Published var connectedPeripherals: [CBPeripheral] = [] // All connected peripherals
    @Published var activePeripheral: CBPeripheral? // Peripheral currently shown in UI
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
    
    // MARK: - Sync Properties
    @Published var syncState: SyncState = .idle
    @Published var lastSyncTimestamp: Date? = nil  // Persisted in UserDefaults
    private var syncTimeoutTimer: Timer?
    private var syncReceivedCount: Int = 0
    private var lastSyncNotificationTime: Date?
    private let syncTimeoutInterval: TimeInterval = 1.0  // Complete sync when no notification for 1 second
    private var deviceEpochOffset: TimeInterval = 0  // Device's epoch offset for timestamp calculation
    
    // Store last known values per device so we can swap views instantly
    private var deviceSnapshots: [UUID: DeviceSnapshot] = [:]
    
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
    let syncDataCharUUID = CBUUID(string: "475f3487-c251-4fbe-b006-37eba1d6c42e") // Sync Data ID Characteristic

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        loadCharacteristicNames()
        requestNotificationPermission()
        loadLastSyncTimestamp()
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
        characteristicNameCache[syncDataCharUUID] = "Sync Data"
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
            if !self.connectedPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
                self.connectedPeripherals.append(peripheral)
            }
            if self.activePeripheral == nil { self.activePeripheral = peripheral }
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
            self.connectedPeripherals.removeAll { $0.identifier == peripheral.identifier }
            if self.activePeripheral?.identifier == peripheral.identifier {
                self.activePeripheral = self.connectedPeripherals.first
            }
            
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
                characteristic.uuid == calibrationCharUUID ||
                characteristic.uuid == syncDataCharUUID {
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

        // Ensure we have a snapshot object for this peripheral
        var snapshot = deviceSnapshots[peripheral.identifier] ?? DeviceSnapshot()

        // Parse and assign characteristic values using proper decoding functions
        switch characteristic.uuid {
        case co2CharUUID:
            if let decodedValue = decodeCO2Measurement(from: stringValue) {
                snapshot.co2 = decodedValue
                if peripheral.identifier == activePeripheral?.identifier { co2Value = decodedValue }
                print("CO2 decoded: \(decodedValue) PPM")
            } else {
                print("Failed to decode CO2 value from: \(stringValue)")
            }
        case tempCharUUID:
            if let decodedTemp = decodeTemperatureMeasurement(from: stringValue) {
                snapshot.temp = decodedTemp.temperature
                snapshot.isCelsius = decodedTemp.isCelsius
                if peripheral.identifier == activePeripheral?.identifier {
                    tempValue = decodedTemp.temperature
                    isTempCelsius = decodedTemp.isCelsius
                }
                print("Temperature decoded: \(decodedTemp.temperature)° \(decodedTemp.isCelsius ? "C" : "F")")
            } else {
                print("Failed to decode temperature value from: \(stringValue)")
            }
        case humCharUUID:
            if let decodedValue = decodeHumidityMeasurement(from: stringValue) {
                snapshot.hum = decodedValue
                if peripheral.identifier == activePeripheral?.identifier { humValue = decodedValue }
                print("Humidity decoded: \(decodedValue)%")
            } else {
                print("Failed to decode humidity value from: \(stringValue)")
            }
        case batteryLevelUUID:
            if let decodedValue = decodeBatteryLevel(from: stringValue) {
                snapshot.battery = decodedValue
                if peripheral.identifier == activePeripheral?.identifier { batteryLevel = decodedValue }
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
                snapshot.isCelsius = (tempUnit == 0)
                if peripheral.identifier == activePeripheral?.identifier {
                    isTempCelsius = (tempUnit == 0)
                    print("Temperature unit set to \(isTempCelsius ? "Celsius" : "Fahrenheit")")
                }
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
        case syncDataCharUUID:
            // Handle sync data notifications (both historical and live samples)
            handleSyncDataNotification(data: data, peripheral: peripheral)
        default:
            break
        }
        
    // Persist snapshot
    deviceSnapshots[peripheral.identifier] = snapshot

    // Update air quality level based on CO2 values only for active device
        if peripheral.identifier == activePeripheral?.identifier {
            updateAirQualityLevel()
        }
        
        // Save sensor reading to database with device context
        saveSensorReading(peripheral: peripheral)
        
        // Handle notifications for air quality changes (active device only)
        if peripheral.identifier == activePeripheral?.identifier {
            handleAirQualityNotifications()
        }
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
    
    private func saveSensorReading(peripheral: CBPeripheral) {
        guard let context = modelContext else { return }
        
        // Throttle database saves to improve performance
        let now = Date()
        guard now.timeIntervalSince(lastSaveTime) >= minimumSaveInterval else { return }
        
        let reading = SensorReading(
            co2Value: co2Value,
            temperature: tempValue,
            humidity: humValue,
            isCelsius: isTempCelsius,
            deviceId: peripheral.identifier.uuidString,
            deviceName: peripheral.name ?? "Unknown"
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
        let target = activePeripheral ?? connectedPeripheral
        guard let peripheral = target,
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
        let target = activePeripheral ?? connectedPeripheral
        guard let peripheral = target,
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
        let target = activePeripheral ?? connectedPeripheral
        guard let peripheral = target, peripheral.state == .connected else {
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

    // MARK: - Multi-device helpers
    func setActivePeripheral(_ peripheral: CBPeripheral) {
        activePeripheral = peripheral
        if let snapshot = deviceSnapshots[peripheral.identifier] {
            co2Value = snapshot.co2
            tempValue = snapshot.temp
            humValue = snapshot.hum
            isTempCelsius = snapshot.isCelsius
            batteryLevel = snapshot.battery
            updateAirQualityLevel()
        }
    }
    
    func activeDeviceDisplayName() -> String {
        activePeripheral?.name ?? "Air Quality"
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
    
    // MARK: - Sync Data Methods
    
    /// Load last sync timestamp from UserDefaults
    private func loadLastSyncTimestamp() {
        if let timestamp = UserDefaults.standard.object(forKey: "lastSyncTimestamp") as? Date {
            lastSyncTimestamp = timestamp
            print("📅 Loaded last sync timestamp: \(timestamp)")
        }
    }
    
    /// Save last sync timestamp to UserDefaults
    private func saveLastSyncTimestamp(_ timestamp: Date) {
        lastSyncTimestamp = timestamp
        UserDefaults.standard.set(timestamp, forKey: "lastSyncTimestamp")
        print("📅 Saved last sync timestamp: \(timestamp)")
    }
    
    /// Request historical/missed data from the device
    /// - Parameter lastSync: Optional last sync timestamp. If nil, uses stored value or requests all data
    func requestSyncData(lastSync: Date? = nil) {
        let target = activePeripheral ?? connectedPeripheral
        guard let peripheral = target, peripheral.state == .connected else {
            print("❌ No connected peripheral to request sync data")
            DispatchQueue.main.async {
                self.syncState = .failed(message: "No connected device")
            }
            return
        }
        
        // Find the sync data characteristic
        guard let services = peripheral.services else {
            print("❌ No services discovered yet")
            DispatchQueue.main.async {
                self.syncState = .failed(message: "Services not discovered")
            }
            return
        }
        
        for service in services {
            guard let characteristics = service.characteristics else { continue }
            for characteristic in characteristics where characteristic.uuid == syncDataCharUUID {
                // Prepare sync data (8 bytes)
                let syncData = encodeSyncDataRequest(lastSync: lastSync)
                
                // Reset sync state
                DispatchQueue.main.async {
                    self.syncReceivedCount = 0
                    self.syncState = .syncing(progress: 0, receivedCount: 0)
                    self.lastSyncNotificationTime = Date()
                }
                
                // Write the sync request
                writeValue(for: characteristic, of: peripheral, value: syncData)
                print("📤 Sync data request sent")
                
                // Start timeout timer
                startSyncTimeoutTimer()
                return
            }
        }
        
        print("❌ Sync data characteristic not found")
        DispatchQueue.main.async {
            self.syncState = .failed(message: "Sync characteristic not found")
        }
    }
    
    /// Encode sync data request as 8 bytes
    /// - MSB (bytes 0-3): Current device absolute timestamp (Unix epoch)
    /// - LSB (bytes 4-7): Last sync timestamp (Unix epoch)
    private func encodeSyncDataRequest(lastSync: Date? = nil) -> Data {
        var data = Data(count: 8)
        
        // Current timestamp (big-endian for MSB)
        let currentTimestamp = UInt32(Date().timeIntervalSince1970)
        data[0] = UInt8((currentTimestamp >> 24) & 0xFF)
        data[1] = UInt8((currentTimestamp >> 16) & 0xFF)
        data[2] = UInt8((currentTimestamp >> 8) & 0xFF)
        data[3] = UInt8(currentTimestamp & 0xFF)
        
        // Last sync timestamp (big-endian for LSB, or 0 if never synced)
        let syncTimestamp = lastSync ?? lastSyncTimestamp ?? Date(timeIntervalSince1970: 0)
        let lastSyncEpoch = UInt32(syncTimestamp.timeIntervalSince1970)
        data[4] = UInt8((lastSyncEpoch >> 24) & 0xFF)
        data[5] = UInt8((lastSyncEpoch >> 16) & 0xFF)
        data[6] = UInt8((lastSyncEpoch >> 8) & 0xFF)
        data[7] = UInt8(lastSyncEpoch & 0xFF)
        
        print("📤 Sync request - Current: \(currentTimestamp), LastSync: \(lastSyncEpoch)")
        
        // Store the epoch offset for computing absolute timestamps
        deviceEpochOffset = Date().timeIntervalSince1970 - Double(currentTimestamp)
        
        return data
    }
    
    /// Handle sync data notifications from the device
    private func handleSyncDataNotification(data: Data, peripheral: CBPeripheral) {
        // Parse the sensor sample from the notification data
        guard let sample = decodeSensorSample(from: data) else {
            print("⚠️ Failed to decode sensor sample from sync notification")
            return
        }
        
        // Update last notification time for timeout tracking
        lastSyncNotificationTime = Date()
        
        // Increment received count
        syncReceivedCount += 1
        
        // Update sync state with progress
        DispatchQueue.main.async {
            // Progress is indeterminate for historical data, just show count
            self.syncState = .syncing(progress: 0, receivedCount: self.syncReceivedCount)
        }
        
        // Restart timeout timer
        startSyncTimeoutTimer()
        
        // Process the sample
        if sample.isHistorical {
            print("📥 Historical sample #\(syncReceivedCount): CO2=\(sample.co2), Temp=\(Double(sample.temperatureC)/100.0)°C, Hum=\(Double(sample.humidity)/100.0)%, Time=\(sample.timestamp)")
            
            // Save historical sample to database
            saveHistoricalSample(sample, peripheral: peripheral)
        } else {
            print("📡 Live sample: CO2=\(sample.co2), Temp=\(Double(sample.temperatureC)/100.0)°C, Hum=\(Double(sample.humidity)/100.0)%")
            
            // Update live values
            updateLiveValues(from: sample, peripheral: peripheral)
        }
        
        // Update last sync timestamp to the sample's timestamp
        if sample.timestamp > (lastSyncTimestamp ?? Date.distantPast) {
            saveLastSyncTimestamp(sample.timestamp)
        }
    }
    
    /// Decode a sensor sample from notification data
    /// Expected format: [uptime_sec(4)][co2(2)][temp(2)][humidity(2)][flags(1)] = 11 bytes minimum
    private func decodeSensorSample(from data: Data) -> SensorSample? {
        guard data.count >= 11 else {
            print("⚠️ Sync data too short: \(data.count) bytes (expected 11+)")
            return nil
        }
        
        // Parse uptime in seconds (4 bytes, big-endian)
        let uptimeSec = UInt32(data[0]) << 24 |
                        UInt32(data[1]) << 16 |
                        UInt32(data[2]) << 8 |
                        UInt32(data[3])
        
        // Parse CO2 (2 bytes, little-endian)
        let co2 = Int16(data[4]) | (Int16(data[5]) << 8)
        
        // Parse temperature (2 bytes, little-endian, in centidegrees Celsius)
        let tempRaw = Int16(bitPattern: UInt16(data[6]) | (UInt16(data[7]) << 8))
        
        // Parse humidity (2 bytes, little-endian, in centipercent)
        let humRaw = Int16(bitPattern: UInt16(data[8]) | (UInt16(data[9]) << 8))
        
        // Parse flags (1 byte)
        let flags = data[10]
        
        // Compute absolute timestamp: current epoch time when sync was requested + uptime offset
        // The device sends its uptime, we compute the absolute timestamp using the epoch offset
        let absoluteTimestamp = Date(timeIntervalSince1970: deviceEpochOffset + Double(uptimeSec))
        
        return SensorSample(
            timestamp: absoluteTimestamp,
            co2: co2,
            temperatureC: tempRaw,
            humidity: humRaw,
            flags: flags
        )
    }
    
    /// Save a historical sample to the database
    private func saveHistoricalSample(_ sample: SensorSample, peripheral: CBPeripheral) {
        guard let context = modelContext else { return }
        
        let reading = sample.toSensorReading(
            deviceId: peripheral.identifier.uuidString,
            deviceName: peripheral.name ?? "Unknown"
        )
        
        context.insert(reading)
        
        // Batch save every 50 samples for performance
        if syncReceivedCount % 50 == 0 {
            do {
                try context.save()
                print("💾 Saved batch of historical readings (\(syncReceivedCount) total)")
            } catch {
                print("❌ Failed to save historical readings: \(error)")
            }
        }
    }
    
    /// Update live sensor values from a sample
    private func updateLiveValues(from sample: SensorSample, peripheral: CBPeripheral) {
        var snapshot = deviceSnapshots[peripheral.identifier] ?? DeviceSnapshot()
        
        snapshot.co2 = Double(sample.co2)
        snapshot.temp = Double(sample.temperatureC) / 100.0
        snapshot.hum = Double(sample.humidity) / 100.0
        snapshot.isCelsius = true
        
        deviceSnapshots[peripheral.identifier] = snapshot
        
        if peripheral.identifier == activePeripheral?.identifier {
            DispatchQueue.main.async {
                self.co2Value = snapshot.co2
                self.tempValue = snapshot.temp
                self.humValue = snapshot.hum
                self.isTempCelsius = snapshot.isCelsius
                self.updateAirQualityLevel()
            }
        }
    }
    
    /// Start or restart the sync timeout timer
    private func startSyncTimeoutTimer() {
        // Invalidate existing timer
        syncTimeoutTimer?.invalidate()
        
        // Create new timer on main thread
        DispatchQueue.main.async {
            self.syncTimeoutTimer = Timer.scheduledTimer(withTimeInterval: self.syncTimeoutInterval, repeats: false) { [weak self] _ in
                self?.handleSyncTimeout()
            }
        }
    }
    
    /// Handle sync timeout (no notification received for 1 second)
    private func handleSyncTimeout() {
        syncTimeoutTimer?.invalidate()
        syncTimeoutTimer = nil
        
        // Final save of any remaining samples
        if let context = modelContext {
            do {
                try context.save()
                print("💾 Final save of historical readings completed")
            } catch {
                print("❌ Failed to save final historical readings: \(error)")
            }
        }
        
        DispatchQueue.main.async {
            if self.syncReceivedCount > 0 {
                self.syncState = .completed(totalReceived: self.syncReceivedCount)
                print("✅ Sync completed: \(self.syncReceivedCount) samples received")
            } else {
                // No samples received - either up to date or no historical data
                self.syncState = .completed(totalReceived: 0)
                print("✅ Sync completed: Device is up to date (no historical data)")
            }
        }
    }
    
    /// Cancel an ongoing sync operation
    func cancelSync() {
        syncTimeoutTimer?.invalidate()
        syncTimeoutTimer = nil
        
        DispatchQueue.main.async {
            self.syncState = .idle
        }
        print("🛑 Sync cancelled")
    }
    
    /// Check if sync is currently in progress
    var isSyncing: Bool {
        return syncState.isSyncing
    }
}
