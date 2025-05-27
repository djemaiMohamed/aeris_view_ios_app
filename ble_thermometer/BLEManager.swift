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
    @Published var isTempCelsius: Bool = true // Temperature unit flag
    @Published var isConnecting: Bool = false
    @Published var connectionStatus: String = "Disconnected"
    @Published var airQualityLevel: AirQualityLevel = .excellent
    @Published var lastUpdateTime: Date = Date()
    
    // MARK: - BLE Core Properties
    var centralManager: CBCentralManager!
    var serviceDiscoveryCompletion: (([CBService]) -> Void)?
    var readValueCompletion: [CBUUID: (String) -> Void] = [:]
    var characteristicNameCache: [CBUUID: String] = [:]
    var modelContext: ModelContext?
    
    // MARK: - Notification Properties
    private var lastNotificationTime: Date?
    private var poorAirQualityStartTime: Date?
    private let notificationCooldownPeriod: TimeInterval = 300 // 5 minutes
    private let poorAirQualityThreshold: TimeInterval = 300 // 5 minutes

    // Replace these UUIDs with your actual service and characteristic UUIDs
    let targetServiceUUID = CBUUID(string: "1809")
    let co2CharUUID = CBUUID(string: "30171109-f957-45e4-81ef-f0c8e64116ea")
    let tempCharUUID = CBUUID(string: "2A1C")
    let humCharUUID = CBUUID(string: "2A6F")

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
        loadCharacteristicNames()
        requestNotificationPermission()
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
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
    
    /// Determines if a device should be prioritized for connection
    /// - Parameters:
    ///   - peripheral: The BLE peripheral
    ///   - rssi: Signal strength
    ///   - advertisedServices: Services advertised by the device
    /// - Returns: Priority level (higher is better)
    func getDevicePriority(_ peripheral: CBPeripheral, rssi: NSNumber, advertisedServices: [CBUUID]) -> Int {
        var priority = 0
        
        // Highest priority: Air Quality devices
        if isAirQualityDevice(peripheral) {
            priority += 100
        }
        
        // High priority: Devices with target service
        if advertisedServices.contains(targetServiceUUID) {
            priority += 50
        }
        
        // Medium priority: Strong signal
        if rssi.intValue > -60 {
            priority += 20
        } else if rssi.intValue > -70 {
            priority += 10
        }
        
        // Low priority: Has a name
        if peripheral.name?.isEmpty == false {
            priority += 5
        }
        
        return priority
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
        peripheral.discoverServices([targetServiceUUID])
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
        let devicePriority = getDevicePriority(peripheral, rssi: RSSI, advertisedServices: advertisedServices)
        
        // Add device to list based on priority (threshold of 5 or higher, or if it's an Air Quality device)
        if isAirQuality || devicePriority >= 5 {
            if !peripherals.contains(peripheral) {
                // Insert Air Quality devices at the beginning for priority
                if isAirQuality {
                    peripherals.insert(peripheral, at: 0)
                    print("🎯 PRIORITY: Air Quality device added first: \(deviceName) | RSSI: \(RSSI) | Priority: \(devicePriority)")
                } else {
                    peripherals.append(peripheral)
                    print("✅ Added device: \(deviceName) | RSSI: \(RSSI) | Priority: \(devicePriority) | Target Service: \(hasTargetService ? "Yes" : "No")")
                }
            } else if isAirQuality {
                // Move existing Air Quality device to front if not already there
                if let index = peripherals.firstIndex(of: peripheral), index != 0 {
                    peripherals.remove(at: index)
                    peripherals.insert(peripheral, at: 0)
                    print("🔄 Moved Air Quality device to priority position: \(deviceName)")
                }
            }
        } else {
            print("⏭️ Skipped device: \(deviceName) | RSSI: \(RSSI) | Priority: \(devicePriority) (below threshold)")
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        DispatchQueue.main.async {
            self.connectedPeripheral = peripheral
            self.isConnecting = false
            self.connectionStatus = "Connected"
            peripheral.discoverServices([self.targetServiceUUID])
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

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            // Enable notifications for relevant characteristics
            if characteristic.uuid == co2CharUUID ||
                characteristic.uuid == tempCharUUID ||
                characteristic.uuid == humCharUUID {
                peripheral.setNotifyValue(true, for: characteristic)
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

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("Error updating notification state: \(error.localizedDescription)")
        } else {
            print("Notification state updated for \(characteristic.uuid)")
        }
    }
    
    // MARK: - Device Management
    func forgetBondedDevice() {
        UserDefaults.standard.removeObject(forKey: "bondedDeviceUUID")
        isBonded = false
        bondedPeripheral = nil
        // Optionally, disconnect if currently connected to this peripheral
        if let connectedPeripheral = connectedPeripheral, connectedPeripheral.identifier.uuidString == UserDefaults.standard.string(forKey: "bondedDeviceUUID") {
            disconnect(peripheral: connectedPeripheral)
        }
        print("🗑️ Forgotten bonded device.")
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
        airQualityLevel = getAirQualityLevel(co2: co2Value)
        lastUpdateTime = Date()
    }
    
    private func handleAirQualityNotifications() {
        // Check if air quality is poor and notification cooldown has passed
        if airQualityLevel == .poor || airQualityLevel == .veryPoor {
            if poorAirQualityStartTime == nil {
                poorAirQualityStartTime = Date()
            }
            
            let timeSincePoorAirQuality = Date().timeIntervalSince(poorAirQualityStartTime ?? Date())
            let timeSinceLastNotification = lastNotificationTime?.timeIntervalSinceNow ?? -notificationCooldownPeriod
            
            if timeSincePoorAirQuality > poorAirQualityThreshold && 
               abs(timeSinceLastNotification) > notificationCooldownPeriod {
                scheduleAirQualityNotification()
            }
        } else {
            poorAirQualityStartTime = nil
        }
    }
    
    private func scheduleAirQualityNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Air Quality Alert"
        content.body = "CO2 levels are \(airQualityLevel.rawValue.lowercased()) (\(Int(co2Value)) PPM). Consider improving ventilation."
        content.sound = UNNotificationSound.default
        
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger)

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error scheduling notification: \(error)")
            } else {
                print("Air quality notification scheduled")
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
}
