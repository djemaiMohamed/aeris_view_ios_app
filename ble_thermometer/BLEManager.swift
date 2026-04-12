import CoreBluetooth
import SwiftData
import UserNotifications
import SwiftUI
import Foundation
import UIKit

class BLEManager: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    // Per-device state for multi-device support
    struct DeviceSnapshot {
        var co2: Double = 0
        var temp: Double = 0
        var hum: Double = 0
        var isCelsius: Bool = true
        var battery: Int = 0
        var lastUpdateTime: Date = Date()
        var measurementInterval: Int = 300
        var temperatureUnit: TemperatureUnit = .celsius
        var co2AlertThreshold: Double = 2000
        var calibrationInProgress: Bool = false
        var calibrationFinished: Bool = false
        var calibrationStatusMessage: String = ""
        var customName: String? = nil
        var isSimpleDisplayMode: Bool = false
    }

    private enum SyncCompletionReason {
        case done(samplesSent: Int)
        case abort(samplesSent: Int, reason: String)
        case timeout
    }
    
    private struct SyncSessionContext {
        let totalSamples: Int
        let oldestIndex: Int
        let protocolVersion: UInt8
        let effectiveStartIndex: Int
        let deviceUptimeAtSyncStart: UInt32  // Device uptime from SYNC_START frame
        let phoneTimeAtSyncStart: TimeInterval  // Phone time when sync started (for timestamp calculation)
        var samplesReceived: Int = 0
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
    @Published var measurementInterval: Int = 300 // Measurement interval in seconds
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
    private let minimumSyncTimeout: TimeInterval = 180.0   // Minimum timeout for sync (seconds)
    private let maximumSyncTimeout: TimeInterval = 900.0   // Cap sync timeout (seconds)
    private let perSampleTimeoutAllowance: TimeInterval = 0.75 // Allowance per sample (seconds)
    private var currentSyncTimeoutInterval: TimeInterval?
    private var syncSessionContext: SyncSessionContext?
    private let ringIndexModulo: Int = 3000 // Device buffer size: max 3000 samples, then wraps to 0
    private var latestSyncedSampleDate: Date?
    private var lastSyncStartIndex: Int = 0  // Persisted requested start index for next sync
    private var requestedSyncStartIndex: Int = 0  // Start index used for the in-flight sync
    private var currentDeviceUptimeSec: UInt32 = 0  // Current device uptime for timestamp calculation (simplified protocol)
    
    // Store last known values per device so we can swap views instantly
    private var deviceSnapshots: [UUID: DeviceSnapshot] = [:]
    
    // MARK: - Custom Device Names (persisted in UserDefaults)
    @Published var customDeviceNames: [String: String] = [:] // [UUID string : custom name]
    
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
    private var syncNotificationsPendingSetup: Set<CBUUID> = [] // Track which characteristics need notifications after sync setup
    private var syncDataNotificationsEnabled: [CBPeripheral: Bool] = [:] // Track sync data notification state per device

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
    let displayModeCharUUID = CBUUID(string: "c9377172-d38c-41ee-9249-e5ebffb0c811") // Display Mode Characteristic

    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: "AirQualityCentralRestore"
            ]
        )
        loadCharacteristicNames()
        requestNotificationPermission()
        loadLastSyncTimestamp()
        loadLastSyncStartIndex()
        loadCustomDeviceNames()
        registerLifecycleNotifications()
    }
    
    func setModelContext(_ context: ModelContext) {
        self.modelContext = context
    }
    
    func setUserSettings(_ settings: UserSettings) {
        self.userSettings = settings
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func registerLifecycleNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }

    @objc private func handleWillEnterForeground() {
        attemptReconnectIfNeeded()
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
        characteristicNameCache[displayModeCharUUID] = "Display Mode"
    }

    func getCharacteristicName(uuid: CBUUID) -> String {
        return characteristicNameCache[uuid] ?? "Unknown Characteristic"
    }

    // MARK: - Aeris View Device Detection

    /// Checks if a peripheral is an Aeris View sensor device
    /// - Parameter peripheral: The BLE peripheral to check
    /// - Returns: True if the device name starts with "Aeris View"
    func isAirQualityDevice(_ peripheral: CBPeripheral) -> Bool {
        guard let name = peripheral.name else { return false }
        return name.hasPrefix("Aeris View")
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
        print("🔍 Scanning started - prioritizing Aeris View devices")
        print("📡 Looking for devices with names starting with 'Aeris View'")
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

    /// Attempt reconnection when app returns to foreground or if connection dropped
    func attemptReconnectIfNeeded() {
        if let connected = connectedPeripheral, connected.state == .connected {
            return
        }
        reconnectToBondedDevice(with: centralManager)
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

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] {
            for peripheral in peripherals {
                peripheral.delegate = self
                if !connectedPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
                    connectedPeripherals.append(peripheral)
                }
            }
            connectedPeripheral = peripherals.first
            activePeripheral = connectedPeripheral ?? activePeripheral
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
        
        // Check if this is an Aeris View device using helper function
        let isAirQuality = isAirQualityDevice(peripheral)

        // Add device to list with size limit to prevent memory issues
        if isAirQuality && !peripherals.contains(peripheral) {
            // Limit the number of peripherals to prevent memory bloat
            if peripherals.count >= 50 {
                peripherals.removeFirst(10) // Remove oldest 10 when limit reached
            }
            peripherals.append(peripheral)
            print("Aeris View device added: \(deviceName)")
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
            
            // Cancel any ongoing sync if device disconnects during sync
            if self.syncState.isSyncing {
                self.syncTimeoutTimer?.invalidate()
                self.syncTimeoutTimer = nil
                self.syncSessionContext = nil
                self.latestSyncedSampleDate = nil
                self.syncState = .failed(message: "Device disconnected during sync")
                print("❌ Sync failed: Device disconnected during sync")
            }

            // Attempt to reconnect if bonded
            self.attemptReconnectIfNeeded()
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
        
        // First, find and enable sync data notifications FIRST
        // This is critical - the device firmware requires sync notifications to be set up before live data can work
        var syncDataChar: CBCharacteristic?
        for characteristic in characteristics {
            if characteristic.uuid == syncDataCharUUID {
                syncDataChar = characteristic
                break
            }
        }
        
        // Enable sync data notifications first if found
        if let syncDataChar = syncDataChar {
            if !syncDataChar.properties.contains(.indicate) {
                print("⚠️ sync_data_id characteristic does not expose indicate; indications are required by firmware")
            }
            peripheral.setNotifyValue(true, for: syncDataChar) // iOS handles notify vs indicate per properties
            print("🔔 Sync data indications enabled first (required by device firmware)")
            // Mark that we're waiting for sync setup to complete
            syncDataNotificationsEnabled[peripheral] = false
            return
        }
        
        // After sync data notifications are confirmed (in didUpdateNotificationStateFor), enable other characteristics
        for characteristic in characteristics {
            // Skip sync data as it's already handled
            if characteristic.uuid == syncDataCharUUID {
                continue
            }
            
            // Enable notifications for relevant characteristics
            if characteristic.uuid == co2CharUUID ||
                characteristic.uuid == tempCharUUID ||
                characteristic.uuid == humCharUUID ||
                characteristic.uuid == batteryLevelUUID ||
                characteristic.uuid == calibrationCharUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }

            if characteristic.uuid == measurementIntervalUUID {
                peripheral.readValue(for: characteristic)
            }

            if characteristic.uuid == tempUnitCharUUID {
                peripheral.readValue(for: characteristic)
            }

            if characteristic.uuid == displayModeCharUUID {
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
                snapshot.measurementInterval = interval
                if peripheral.identifier == activePeripheral?.identifier {
                    measurementInterval = interval
                }
                print("Measurement interval set to \(interval) seconds")
                
                // Update UserSettings if available (only for active device)
                if peripheral.identifier == activePeripheral?.identifier,
                   let settings = userSettings {
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
                let isCelsius = (tempUnit == 0)
                snapshot.isCelsius = isCelsius
                snapshot.temperatureUnit = isCelsius ? .celsius : .fahrenheit
                if peripheral.identifier == activePeripheral?.identifier {
                    isTempCelsius = isCelsius
                    print("Temperature unit set to \(isCelsius ? "Celsius" : "Fahrenheit")")

                    if let settings = userSettings {
                        settings.temperatureUnit = isCelsius ? .celsius : .fahrenheit
                        try? modelContext?.save()
                        print("📱 UserSettings temperature unit updated to \(isCelsius ? "Celsius" : "Fahrenheit")")
                    }
                }
            } else {
                print("Failed to decode temperature unit from: \(stringValue)")
            }
        case displayModeCharUUID:
            print("Display mode updated: \(stringValue)")
            if data.count >= 1 {
                let isSimple = data[0] == 1
                snapshot.isSimpleDisplayMode = isSimple
                if peripheral.identifier == activePeripheral?.identifier {
                    if let settings = userSettings {
                        settings.isSimpleDisplayMode = isSimple
                        try? modelContext?.save()
                        print("📱 UserSettings display mode updated to \(isSimple ? "simple" : "default")")
                    }
                }
            } else {
                print("Failed to decode display mode from: \(stringValue)")
            }
        case calibrationCharUUID:
            // Device sends 0x01 when calibration finishes
            if data.count >= 1, data[0] == 0x01 {
                // Update per-device calibration state
                var calSnap = deviceSnapshots[peripheral.identifier] ?? DeviceSnapshot()
                calSnap.calibrationInProgress = false
                calSnap.calibrationFinished = true
                calSnap.calibrationStatusMessage = "Calibration finished."
                deviceSnapshots[peripheral.identifier] = calSnap
                
                if peripheral.identifier == activePeripheral?.identifier {
                    DispatchQueue.main.async {
                        self.calibrationInProgress = false
                        self.calibrationFinished = true
                        self.calibrationStatusMessage = "Calibration finished."
                    }
                }
                print("✅ Calibration finished notification received")
            } else {
                print("Calibration characteristic updated: \(stringValue)")
            }
        case syncDataCharUUID:
            // Handle sync data notifications (both historical and live samples)
            // Sync handler manages its own snapshots and saves – return early
            // to avoid overwriting snapshot with the stale local copy.
            handleSyncDataNotification(data: data, peripheral: peripheral)
            return
        default:
            break
        }

    // Update per-device update timestamp
    snapshot.lastUpdateTime = Date()

    // Persist snapshot
    deviceSnapshots[peripheral.identifier] = snapshot

    // Update published values & air quality for the active device
        if peripheral.identifier == activePeripheral?.identifier {
            lastUpdateTime = Date()
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
            print("❌ Error updating notification state for \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        
        if characteristic.uuid == syncDataCharUUID {
            if characteristic.isNotifying {
                print("✅ Sync data notifications successfully enabled")
                syncDataNotificationsEnabled[peripheral] = true
                
                // Now enable live data notifications after sync data is confirmed
                enableLiveDataNotifications(for: peripheral)
            } else {
                print("⚠️ Sync data notifications disabled")
                syncDataNotificationsEnabled[peripheral] = false
            }
        } else {
            print("✅ Notification state updated for \(characteristic.uuid)")
        }
        
        // Update bonding status
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "bondedDeviceUUID")
        isBonded = true
        bondedPeripheral = peripheral
        print("🔗 Bonded to device: \(peripheral.name ?? "Unknown")")
    }
    
    /// Enable live data notifications after sync data notifications are established,
    /// and read config characteristics to sync device state into the app UI.
    private func enableLiveDataNotifications(for peripheral: CBPeripheral) {
        guard let services = peripheral.services else {
            print("⚠️ Services not discovered yet for live data notifications")
            return
        }

        for service in services {
            guard let characteristics = service.characteristics else { continue }
            for characteristic in characteristics {
                // Enable notifications for live data characteristics
                if characteristic.uuid == co2CharUUID ||
                    characteristic.uuid == tempCharUUID ||
                    characteristic.uuid == humCharUUID ||
                    characteristic.uuid == batteryLevelUUID ||
                    characteristic.uuid == calibrationCharUUID {
                    peripheral.setNotifyValue(true, for: characteristic)
                    print("🔔 Enabled notifications for \(getCharacteristicName(uuid: characteristic.uuid))")
                }

                // Read config characteristics so the app UI stays in sync with the device
                if characteristic.uuid == measurementIntervalUUID ||
                    characteristic.uuid == tempUnitCharUUID ||
                    characteristic.uuid == displayModeCharUUID {
                    peripheral.readValue(for: characteristic)
                    print("📖 Reading \(getCharacteristicName(uuid: characteristic.uuid)) from device")
                }
            }
        }
    }

    /// Ensure sync data channel is fully configured (notifications + CCCD) before proceeding
    private func attemptSyncReady(for peripheral: CBPeripheral) {
        // No-op placeholder retained for potential future gating; iOS manages CCCD via setNotifyValue
        let notifyReady = syncDataNotificationsEnabled[peripheral] == true
        if notifyReady {
            enableLiveDataNotifications(for: peripheral)
        }
    }

    // MARK: - Data Management
    private var lastSaveTimes: [UUID: Date] = [:]
    private let minimumSaveInterval: TimeInterval = 60 // Save at most once per minute
    
    private func saveSensorReading(peripheral: CBPeripheral) {
        guard let context = modelContext else { return }
        
        // Throttle database saves per device to improve performance
        let now = Date()
        let lastSave = lastSaveTimes[peripheral.identifier] ?? .distantPast
        guard now.timeIntervalSince(lastSave) >= minimumSaveInterval else { return }
        
        // Use per-device snapshot so background devices save their own values
        let snapshot = deviceSnapshots[peripheral.identifier] ?? DeviceSnapshot()
        guard snapshot.co2 > 0 else { return } // Don't save empty readings
        
        let reading = SensorReading(
            co2Value: snapshot.co2,
            temperature: snapshot.temp,
            humidity: snapshot.hum,
            isCelsius: snapshot.isCelsius,
            deviceId: peripheral.identifier.uuidString,
            deviceName: displayName(for: peripheral)
        )
        
        context.insert(reading)
        
        do {
            try context.save()
            lastSaveTimes[peripheral.identifier] = now
            
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
    
    /// Automatically connects to the first Aeris View device found
    /// - Returns: True if an Aeris View device was found and connection initiated
    func connectToFirstAirQualityDevice() -> Bool {
        guard let airQualityDevice = peripherals.first(where: { isAirQualityDevice($0) }) else {
            print("❌ No Aeris View devices found in scan results")
            return false
        }

        print("🎯 Auto-connecting to Aeris View device: \(airQualityDevice.name ?? "Unknown")")
        connect(peripheral: airQualityDevice)
        return true
    }

    /// Gets all Aeris View devices from the current scan results
    /// - Returns: Array of Aeris View device peripherals
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
                    
                    // Immediately persist to the device snapshot so the value
                    // survives device switches (this char is read-only, not notified,
                    // so no BLE callback will update the snapshot after the write).
                    var snap = deviceSnapshots[peripheral.identifier] ?? DeviceSnapshot()
                    snap.measurementInterval = interval
                    deviceSnapshots[peripheral.identifier] = snap
                    measurementInterval = interval
                    
                    // Re-read from device to confirm the written value
                    peripheral.readValue(for: characteristic)
                    
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
                    
                    // Immediately persist to the device snapshot (same reason as
                    // measurement interval – this char is read-only, not notified).
                    var snap = deviceSnapshots[peripheral.identifier] ?? DeviceSnapshot()
                    snap.isCelsius = isCelsius
                    snap.temperatureUnit = isCelsius ? .celsius : .fahrenheit
                    deviceSnapshots[peripheral.identifier] = snap
                    self.isTempCelsius = isCelsius
                    
                    // Re-read from device to confirm
                    peripheral.readValue(for: characteristic)
                    
                    print("📝 Writing temperature unit: \(isCelsius ? "Celsius" : "Fahrenheit")")
                    return
                }
            }
        }
        print("❌ Temperature unit characteristic not found")
    }

    /// Writes display mode to the connected BLE device (0 = default, 1 = simple)
    func writeDisplayMode(_ isSimple: Bool) {
        let target = activePeripheral ?? connectedPeripheral
        guard let peripheral = target,
              peripheral.state == .connected else {
            print("No connected peripheral to write display mode")
            return
        }

        guard let services = peripheral.services else { return }
        for service in services {
            guard let characteristics = service.characteristics else { continue }
            for characteristic in characteristics {
                if characteristic.uuid == displayModeCharUUID {
                    let modeValue: UInt8 = isSimple ? 1 : 0
                    let data = Data([modeValue])
                    writeValue(for: characteristic, of: peripheral, value: data)
                    print("📝 Writing display mode: \(isSimple ? "simple" : "default")")
                    return
                }
            }
        }
        print("❌ Display mode characteristic not found")
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
        // Track per-device calibration state
        var calSnap = deviceSnapshots[peripheral.identifier] ?? DeviceSnapshot()
        calSnap.calibrationInProgress = true
        calSnap.calibrationFinished = false
        calSnap.calibrationStatusMessage = calibrationStatusMessage
        deviceSnapshots[peripheral.identifier] = calSnap
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
        // Update per-device snapshot on failure
        var failSnap = deviceSnapshots[peripheral.identifier] ?? DeviceSnapshot()
        failSnap.calibrationInProgress = false
        failSnap.calibrationStatusMessage = calibrationStatusMessage
        deviceSnapshots[peripheral.identifier] = failSnap
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
        // Save current active device's published values back into its snapshot
        // so nothing is lost when we switch away.
        if let prev = activePeripheral {
            var prevSnap = deviceSnapshots[prev.identifier] ?? DeviceSnapshot()
            prevSnap.co2 = co2Value
            prevSnap.temp = tempValue
            prevSnap.hum = humValue
            prevSnap.isCelsius = isTempCelsius
            prevSnap.battery = batteryLevel
            prevSnap.lastUpdateTime = lastUpdateTime
            prevSnap.measurementInterval = measurementInterval
            prevSnap.calibrationInProgress = calibrationInProgress
            prevSnap.calibrationFinished = calibrationFinished
            prevSnap.calibrationStatusMessage = calibrationStatusMessage
            // Save app-level settings that the user may have changed for this device
            if let settings = userSettings {
                prevSnap.temperatureUnit = settings.temperatureUnit
                prevSnap.co2AlertThreshold = settings.co2AlertThreshold
            }
            deviceSnapshots[prev.identifier] = prevSnap
        }

        activePeripheral = peripheral
        connectedPeripheral = peripheral

        let snapshot = deviceSnapshots[peripheral.identifier] ?? DeviceSnapshot()
        if snapshot.co2 > 0 {
            co2Value = snapshot.co2
            tempValue = snapshot.temp
            humValue = snapshot.hum
            isTempCelsius = snapshot.isCelsius
            batteryLevel = snapshot.battery
            lastUpdateTime = snapshot.lastUpdateTime
            measurementInterval = snapshot.measurementInterval
            calibrationInProgress = snapshot.calibrationInProgress
            calibrationFinished = snapshot.calibrationFinished
            calibrationStatusMessage = snapshot.calibrationStatusMessage
            updateAirQualityLevel()
        } else {
            // No data received yet from this device – show waiting state
            co2Value = 0
            tempValue = 0
            humValue = 0
            isTempCelsius = true
            batteryLevel = 0
            lastUpdateTime = Date()
            measurementInterval = snapshot.measurementInterval
            calibrationInProgress = snapshot.calibrationInProgress
            calibrationFinished = snapshot.calibrationFinished
            calibrationStatusMessage = snapshot.calibrationStatusMessage
            airQualityLevel = .waitingForData
        }

        // Sync all per-device settings into the shared UserSettings
        if let settings = userSettings {
            settings.measurementInterval = measurementInterval
            settings.temperatureUnit = snapshot.temperatureUnit
            settings.co2AlertThreshold = snapshot.co2AlertThreshold
            if let context = modelContext {
                try? context.save()
            }
        }
    }
    
    func activeDeviceDisplayName() -> String {
        if let active = activePeripheral {
            return displayName(for: active)
        }
        return "Aeris View"
    }
    
    /// Returns the display name for a peripheral: custom name > BLE name > "Device N"
    func displayName(for peripheral: CBPeripheral) -> String {
        let uuidStr = peripheral.identifier.uuidString
        if let custom = customDeviceNames[uuidStr], !custom.isEmpty {
            return custom
        }
        if let bleName = peripheral.name, !bleName.isEmpty {
            return bleName
        }
        // Auto-number: find this device's position among connected peripherals
        if let idx = connectedPeripherals.firstIndex(where: { $0.identifier == peripheral.identifier }) {
            return "Device \(idx + 1)"
        }
        return "Unknown Device"
    }
    
    /// Rename a device. Pass nil or empty string to revert to the BLE/default name.
    func renameDevice(_ peripheral: CBPeripheral, to newName: String?) {
        let uuidStr = peripheral.identifier.uuidString
        if let name = newName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            customDeviceNames[uuidStr] = name.trimmingCharacters(in: .whitespaces)
        } else {
            customDeviceNames.removeValue(forKey: uuidStr)
        }
        saveCustomDeviceNames()
        // Also update the snapshot
        var snap = deviceSnapshots[peripheral.identifier] ?? DeviceSnapshot()
        snap.customName = customDeviceNames[uuidStr]
        deviceSnapshots[peripheral.identifier] = snap
    }
    
    private func saveCustomDeviceNames() {
        UserDefaults.standard.set(customDeviceNames, forKey: "customDeviceNames")
    }
    
    private func loadCustomDeviceNames() {
        if let saved = UserDefaults.standard.dictionary(forKey: "customDeviceNames") as? [String: String] {
            customDeviceNames = saved
        }
    }
    
    /// Resets the calibrationFinished flag for the active device so the
    /// completion alert is only shown once (not on every device switch).
    func clearCalibrationFinished() {
        calibrationFinished = false
        if let active = activePeripheral {
            var snap = deviceSnapshots[active.identifier] ?? DeviceSnapshot()
            snap.calibrationFinished = false
            deviceSnapshots[active.identifier] = snap
        }
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
            // Validate timestamp is reasonable (not in the future, not before year 2020)
            let minDate = Date(timeIntervalSince1970: 1577836800) // Jan 1, 2020
            let maxDate = Date().addingTimeInterval(86400) // Tomorrow
            
            if timestamp >= minDate && timestamp <= maxDate {
                lastSyncTimestamp = timestamp
                print("📅 Loaded last sync timestamp: \(timestamp)")
            } else {
                print("⚠️ Invalid last sync timestamp found: \(timestamp), resetting")
                UserDefaults.standard.removeObject(forKey: "lastSyncTimestamp")
                lastSyncTimestamp = nil
            }
        }
    }
    
    /// Reset last sync timestamp to force full sync
    func resetLastSyncTimestamp() {
        UserDefaults.standard.removeObject(forKey: "lastSyncTimestamp")
        lastSyncTimestamp = nil
        print("🔄 Last sync timestamp reset")
    }
    
    /// Save last sync timestamp to UserDefaults
    private func saveLastSyncTimestamp(_ timestamp: Date) {
        lastSyncTimestamp = timestamp
        UserDefaults.standard.set(timestamp, forKey: "lastSyncTimestamp")
        print("📅 Saved last sync timestamp: \(timestamp)")
    }

    /// Load last requested sync start index from UserDefaults
    private func loadLastSyncStartIndex() {
        let stored = UserDefaults.standard.integer(forKey: "lastSyncStartIndex")
        // Bound to valid range [0, ringIndexModulo)
        lastSyncStartIndex = max(0, stored) % ringIndexModulo
        print("📂 Loaded last sync start index: \(lastSyncStartIndex) (bounded to 0-\(ringIndexModulo-1))")
    }
    
    /// Persist next requested sync start index to UserDefaults
    private func saveLastSyncStartIndex(_ index: Int) {
        // Bound to valid range [0, ringIndexModulo)
        lastSyncStartIndex = max(0, index) % ringIndexModulo
        UserDefaults.standard.set(lastSyncStartIndex, forKey: "lastSyncStartIndex")
        print("💾 Saved next sync start index: \(lastSyncStartIndex) (bounded to 0-\(ringIndexModulo-1))")
    }
    
    /// Request historical/missed data from the device
    /// - Parameter lastSync: Optional last sync timestamp. If nil, uses stored value or requests all data
    func requestSyncData(lastSync: Date? = nil) {
        _ = lastSync // kept for compatibility; start index drives sync
        let target = activePeripheral ?? connectedPeripheral
        guard let peripheral = target, peripheral.state == .connected else {
            print("❌ No connected peripheral to request sync data")
            DispatchQueue.main.async {
                self.syncState = .failed(message: "No connected device")
            }
            return
        }

        guard syncDataNotificationsEnabled[peripheral] == true else {
            print("❌ Sync data indications are not enabled; cannot start sync")
            DispatchQueue.main.async {
                self.syncState = .failed(message: "Enable sync indications before syncing")
            }
            return
        }
        print("✅ Sync data channel marked notifying; proceeding to send sync request")
        
        syncSessionContext = nil
        latestSyncedSampleDate = nil
        syncTimeoutTimer?.invalidate()
        
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
                // Prepare sync data (4 bytes) with persisted start index (simplified protocol)
                requestedSyncStartIndex = lastSyncStartIndex % ringIndexModulo
                let syncData = encodeSyncDataRequest(startIndex: requestedSyncStartIndex)
                
                // Reset sync state
                DispatchQueue.main.async {
                    self.syncReceivedCount = 0
                    self.syncState = .syncing(progress: 0, receivedCount: 0)
                    self.lastSyncNotificationTime = Date()
                }
                
                // Write the sync request
                writeValue(for: characteristic, of: peripheral, value: syncData)
                print("📤 Sync data request sent (startIdx=\(requestedSyncStartIndex), simplified protocol)")
                
                // Start timeout timer
                startSyncTimeoutTimer(totalSamples: nil)
                return
            }
        }
        
        print("❌ Sync data characteristic not found")
        DispatchQueue.main.async {
            self.syncState = .failed(message: "Sync characteristic not found")
        }
    }
    
    /// Encode sync data request as 4 bytes (simplified protocol)
    /// - Bytes 0-3: requested start index for device ring buffer (little-endian UInt32)
    /// Phone now handles timestamp calculation - device sends only uptime
    private func encodeSyncDataRequest(startIndex: Int) -> Data {
        var data = Data(count: 4)
        
        // Requested start index (little-endian UInt32)
        let boundedIndex = UInt32(max(0, startIndex) % ringIndexModulo)
        data[0] = UInt8(boundedIndex & 0xFF)
        data[1] = UInt8((boundedIndex >> 8) & 0xFF)
        data[2] = UInt8((boundedIndex >> 16) & 0xFF)
        data[3] = UInt8((boundedIndex >> 24) & 0xFF)
        
        print("📤 Sync request (simplified) - StartIdx: \(boundedIndex)")
        
        return data
    }
    
    /// Handle sync data notifications from the device (indication-driven framed protocol)
    private func handleSyncDataNotification(data: Data, peripheral: CBPeripheral) {
        guard data.count == 12 else {
            print("⚠️ Unexpected sync frame length: \(data.count) bytes (expected 12)")
            return
        }
        
        guard let frameType = SyncFrameType(rawValue: data[10]) else {
            print("⚠️ Unknown frame type: \(data[10])")
            return
        }
        
        switch frameType {
        case .syncStart:
            guard let startFrame = decodeSyncStartFrame(from: data) else { return }
            if startFrame.protocolVersion != 0x01 {
                syncTimeoutTimer?.invalidate()
                syncTimeoutTimer = nil
                syncSessionContext = nil
                DispatchQueue.main.async {
                    self.syncState = .failed(message: "Unsupported sync protocol v\(startFrame.protocolVersion)")
                }
                print("⚠️ Unsupported sync protocol version \(startFrame.protocolVersion)")
                return
            }
            let effectiveStartIndex = resolveEffectiveStartIndex(
                requested: requestedSyncStartIndex,
                oldest: startFrame.oldestIndex,
                totalSamples: startFrame.totalSamples,
                lastSentValid: startFrame.lastSentValid
            )
            let phoneTimeNow = Date().timeIntervalSince1970
            
            // Log device's buffer status
            if startFrame.lastSentValid {
                print("✅ Device indicates last sync point is valid (can resume)")
            } else {
                print("⚠️ Device indicates buffer wrapped; must restart from oldest")
            }
            
            // Log buffer state for debugging
            logCircularBufferState(
                oldest: startFrame.oldestIndex,
                totalSamples: startFrame.totalSamples,
                requested: requestedSyncStartIndex,
                effective: effectiveStartIndex
            )
            
            syncSessionContext = SyncSessionContext(
                totalSamples: startFrame.totalSamples,
                oldestIndex: startFrame.oldestIndex,
                protocolVersion: startFrame.protocolVersion,
                effectiveStartIndex: effectiveStartIndex,
                deviceUptimeAtSyncStart: startFrame.deviceUptime,
                phoneTimeAtSyncStart: phoneTimeNow,
                samplesReceived: 0
            )
            syncReceivedCount = 0
            latestSyncedSampleDate = nil
            lastSyncNotificationTime = Date()
            DispatchQueue.main.async {
                self.syncState = .syncing(progress: 0, receivedCount: 0)
            }
            startSyncTimeoutTimer(totalSamples: startFrame.totalSamples)
            print("🚦 Sync start: total=\(startFrame.totalSamples), oldestIndex=\(startFrame.oldestIndex), proto=\(startFrame.protocolVersion), effectiveStart=\(effectiveStartIndex)")
            print("⏱️ Timestamp reference: phoneTime=\(Int(phoneTimeNow)), bootEpoch=\(Int(phoneTimeNow - TimeInterval(startFrame.deviceUptime)))")
        case .syncData:
            guard let session = syncSessionContext else {
                print("⚠️ Received sync data frame without an active session")
                return
            }
            guard let sample = decodeMeasurementFrame(from: data, frameType: frameType) else { return }
            print("⬇️ Sync data frame ts=\(Int(sample.timestamp.timeIntervalSince1970)) co2=\(sample.co2) tCenti=\(sample.temperatureCentiDegrees) hum=\(sample.humidity) batt=\(sample.battery)")
            
            // Append only if newer than last sync timestamp
            if let lastSync = lastSyncTimestamp, sample.timestamp <= lastSync {
                print("⏭️ Skipping stale sample at \(sample.timestamp) (<= lastSyncTimestamp)")
            } else {
                // Check if we've reached the device buffer limit
                if syncReceivedCount >= ringIndexModulo {
                    print("⚠️ Reached maximum sync limit of \(ringIndexModulo) samples; stopping sync")
                    completeSyncOperation(reason: .done(samplesSent: syncReceivedCount))
                    return
                }
                syncReceivedCount += 1
                var updatedSession = session
                updatedSession.samplesReceived += 1
                syncSessionContext = updatedSession
                latestSyncedSampleDate = max(latestSyncedSampleDate ?? sample.timestamp, sample.timestamp)
                publishSyncProgress()
                saveHistoricalSample(sample, peripheral: peripheral)
            }
            lastSyncNotificationTime = Date()
            // Keep next start index in sync with data received so far
            let rollingNextIndex = computeNextSyncStartIndex(samplesProcessed: syncReceivedCount)
            saveLastSyncStartIndex(rollingNextIndex)
            startSyncTimeoutTimer(totalSamples: syncSessionContext?.totalSamples)
        case .syncDone:
            let samplesSent = decodeSyncDoneFrame(from: data)
            print("🏁 Sync done frame received; samplesSent=\(samplesSent)")
            completeSyncOperation(reason: .done(samplesSent: samplesSent))
        case .syncAbort:
            let abort = decodeSyncAbortFrame(from: data)
            print("🛑 Sync abort frame received; samplesSent=\(abort.samplesSent) reason=\(abort.reason)")
            completeSyncOperation(reason: .abort(samplesSent: abort.samplesSent, reason: abort.reason))
        case .live:
            guard let sample = decodeMeasurementFrame(from: data, frameType: frameType) else { return }
            updateLiveValues(from: sample, peripheral: peripheral)
            saveSensorReading(peripheral: peripheral)
        }
    }

    private func decodeSyncStartFrame(from data: Data) -> (totalSamples: Int, oldestIndex: Int, protocolVersion: UInt8, deviceUptime: UInt32, lastSentValid: Bool)? {
        guard data.count == 12 else { return nil }
        // Parse SYNC_START frame (updated format includes device uptime and last_sent_valid flag):
        // Bytes 0-3: device_uptime (UInt32, little-endian)
        // Bytes 4-5: total_samples (UInt16, little-endian)
        // Bytes 6-7: oldest_idx (UInt16, little-endian)
        // Byte 8: last_sent_valid flag (1 = can resume from last sync, 0 = buffer wrapped, restart)
        // Bytes 9: padding
        // Byte 10: FRAME_SYNC_START
        // Byte 11: padding
        let deviceUptime = UInt32(data[0]) | (UInt32(data[1]) << 8) |
                          (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
        let totalSamples = Int(UInt16(data[4]) | (UInt16(data[5]) << 8))
        let oldestIndex = Int(UInt16(data[6]) | (UInt16(data[7]) << 8))
        let lastSentValid = data[8] != 0
        let protocolVersion = UInt8(0x01)  // Simplified protocol version
        return (totalSamples, oldestIndex, protocolVersion, deviceUptime, lastSentValid)
    }

    private func decodeSyncDoneFrame(from data: Data) -> Int {
        guard data.count >= 2 else { return syncReceivedCount }
        let samplesSent = Int(UInt16(data[0]) | (UInt16(data[1]) << 8))
        return samplesSent
    }

    private func decodeSyncAbortFrame(from data: Data) -> (samplesSent: Int, reason: String) {
        guard data.count >= 7 else {
            return (syncReceivedCount, "Unknown")
        }
        let samplesSent = Int(UInt16(data[0]) | (UInt16(data[1]) << 8))
        let reasonCode = data[6]
        let reason: String
        switch reasonCode {
        case 1:
            reason = "Generic abort"
        default:
            reason = "Abort code \(reasonCode)"
        }
        return (samplesSent, reason)
    }

    /// Decode live or sync data measurement frames (12 bytes, little-endian)
    /// Simplified protocol: Bytes 0-3 contain device uptime (not absolute timestamp)
    /// Phone calculates absolute timestamp using: timestamp = (phoneTimeAtSyncStart - deviceUptimeAtSyncStart) + sampleUptime
    private func decodeMeasurementFrame(from data: Data, frameType: SyncFrameType) -> SensorSample? {
        guard data.count == 12 else {
            print("⚠️ Measurement frame wrong length: \(data.count)")
            return nil
        }
        
        // Bytes 0-3: Device uptime (simplified protocol)
        let uptimeRaw = UInt32(data[0]) |
                        (UInt32(data[1]) << 8) |
                        (UInt32(data[2]) << 16) |
                        (UInt32(data[3]) << 24)
        
        let co2 = Int(UInt16(data[4]) | (UInt16(data[5]) << 8))
        let temperature = Int(Int16(bitPattern: UInt16(data[6]) | (UInt16(data[7]) << 8)))
        let humidity = Int(UInt16(data[8]) | (UInt16(data[9]) << 8))
        let battery = Int(data[11])
        
        // Calculate absolute timestamp using device uptime
        // timestamp = (phoneTime - deviceUptime) + sampleUptime
        let timestamp: TimeInterval
        if let session = syncSessionContext, frameType == .syncData {
            // Use sync session context to calculate timestamp
            let bootEpoch = session.phoneTimeAtSyncStart - TimeInterval(session.deviceUptimeAtSyncStart)
            timestamp = bootEpoch + TimeInterval(uptimeRaw)
            print("⏱️ Timestamp calc: bootEpoch=\(Int(bootEpoch)) + uptime=\(uptimeRaw) = \(Int(timestamp))")
        } else {
            // Fallback: Use current phone time minus assumed device uptime
            let bootEpoch = Date().timeIntervalSince1970 - TimeInterval(uptimeRaw)
            timestamp = bootEpoch + TimeInterval(uptimeRaw)
            print("⏱️ Timestamp calc (no session): uptime=\(uptimeRaw) → timestamp=\(Int(timestamp))")
        }
        
        let sampleDate = Date(timeIntervalSince1970: timestamp)
        return SensorSample(
            timestamp: sampleDate,
            co2: co2,
            temperatureCentiDegrees: temperature,
            humidity: humidity,
            battery: battery,
            frameType: frameType
        )
    }

    /// Save a historical sample to the database
    private func saveHistoricalSample(_ sample: SensorSample, peripheral: CBPeripheral) {
        guard let context = modelContext else { return }
        
        let reading = sample.toSensorReading(
            deviceId: peripheral.identifier.uuidString,
            deviceName: displayName(for: peripheral)
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
        snapshot.temp = Double(sample.temperatureCentiDegrees) / 100.0
        snapshot.hum = Double(sample.humidity)
        snapshot.isCelsius = true
        snapshot.battery = sample.battery
        snapshot.lastUpdateTime = Date()
        
        deviceSnapshots[peripheral.identifier] = snapshot
        
        if peripheral.identifier == activePeripheral?.identifier {
            DispatchQueue.main.async {
                self.co2Value = snapshot.co2
                self.tempValue = snapshot.temp
                self.humValue = snapshot.hum
                self.isTempCelsius = snapshot.isCelsius
                self.batteryLevel = snapshot.battery
                self.lastUpdateTime = Date()
                self.updateAirQualityLevel()
            }
        }
    }
    
    /// Compute a timeout interval based on total samples expected
    private func computeSyncTimeoutInterval(totalSamples: Int?) -> TimeInterval {
        guard let total = totalSamples, total > 0 else {
            return maximumSyncTimeout / 2 // Fallback generous timeout when count unknown
        }
        let estimated = Double(total) * perSampleTimeoutAllowance
        return min(max(estimated, minimumSyncTimeout), maximumSyncTimeout)
    }

    /// Start or restart the sync timeout timer
    private func startSyncTimeoutTimer(totalSamples: Int?) {
        // Invalidate existing timer
        syncTimeoutTimer?.invalidate()
        
        let interval = computeSyncTimeoutInterval(totalSamples: totalSamples)
        currentSyncTimeoutInterval = interval

        // Create new timer on main thread
        DispatchQueue.main.async {
            self.syncTimeoutTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
                self?.handleSyncTimeout()
            }
        }
    }
    
    /// Handle sync timeout (no notification received for timeout period)
    private func handleSyncTimeout() {
        // Prevent multiple calls
        guard syncTimeoutTimer != nil else { return }
        syncTimeoutTimer?.invalidate()
        syncTimeoutTimer = nil
        
        completeSyncOperation(reason: .timeout)
    }
    
    /// Complete the sync operation and update UI
    private func completeSyncOperation(reason: SyncCompletionReason) {
        guard syncState.isSyncing else { return }

        syncTimeoutTimer?.invalidate()
        syncTimeoutTimer = nil
        
        if let context = modelContext {
            do {
                try context.save()
                print("💾 Final save of historical readings completed")
            } catch {
                print("❌ Failed to save final historical readings: \(error)")
            }
        }
        
        let reported = syncSessionContext?.samplesReceived ?? syncReceivedCount
        let totalReceived: Int
        var finalState: SyncState
        var shouldPersistTimestamp = false
        
        // Calculate next index based on effective start and samples received
        let effectiveStart = syncSessionContext?.effectiveStartIndex ?? requestedSyncStartIndex
        
        switch reason {
        case .done(let samplesSent):
            totalReceived = max(samplesSent, reported)
            shouldPersistTimestamp = true
            finalState = .completed(totalReceived: totalReceived)
            print("✅ Sync completed: \(totalReceived) samples received")
            let nextIndex = (effectiveStart + totalReceived) % ringIndexModulo
            saveLastSyncStartIndex(nextIndex)
            print("📍 Next sync start index: \(nextIndex) (based on effective start \(effectiveStart) + \(totalReceived) samples)")
        case .abort(let samplesSent, let reasonText):
            totalReceived = max(samplesSent, reported)
            finalState = .failed(message: "Sync aborted: \(reasonText). Partial data kept; please retry.")
            print("⚠️ Sync aborted after \(totalReceived) samples - reason: \(reasonText)")
            let nextIndex = (effectiveStart + totalReceived) % ringIndexModulo
            saveLastSyncStartIndex(nextIndex)
            print("📍 Next sync start index: \(nextIndex) (based on effective start \(effectiveStart) + \(totalReceived) samples)")
        case .timeout:
            totalReceived = reported
            finalState = .failed(message: "No response from device. Partial data may be saved; please retry.")
            print("⚠️ Sync timeout: No data received - possible connection issue")
            let nextIndex = (effectiveStart + totalReceived) % ringIndexModulo
            saveLastSyncStartIndex(nextIndex)
            print("📍 Next sync start index: \(nextIndex) (based on effective start \(effectiveStart) + \(totalReceived) samples)")
        }
        
        if shouldPersistTimestamp {
            let timestampToSave = latestSyncedSampleDate ?? Date()
            saveLastSyncTimestamp(timestampToSave)
            print("📅 Updated lastSyncTimestamp after successful sync")
        }
        
        DispatchQueue.main.async {
            self.syncState = finalState
        }
        
        syncSessionContext = nil
        latestSyncedSampleDate = nil
        currentSyncTimeoutInterval = nil
    }

    /// Publish sync progress on the main queue for responsive UI updates
    private func publishSyncProgress() {
        let total = syncSessionContext?.totalSamples ?? 0
        let progress = total > 0 ? min(Double(syncReceivedCount) / Double(total), 1.0) : 0
        DispatchQueue.main.async {
            self.syncState = .syncing(progress: progress, receivedCount: self.syncReceivedCount)
        }
    }

    /// Calculate the next start index based on the requested index and samples received
    private func computeNextSyncStartIndex(samplesProcessed: Int) -> Int {
        let baseIndex = syncSessionContext?.effectiveStartIndex ?? requestedSyncStartIndex
        guard samplesProcessed > 0 else { return baseIndex % ringIndexModulo }
        // Ensure result is bounded to valid range [0, ringIndexModulo)
        let next = (baseIndex + samplesProcessed) % ringIndexModulo
        return max(0, next)
    }

    /// Clamp requested start index to the device's valid window
    /// Circular buffer: valid range is [oldestIndex, oldestIndex + totalSamples) with wraparound
    /// lastSentValid flag indicates if last sync point is still valid (buffer hasn't wrapped around)
    private func resolveEffectiveStartIndex(requested: Int, oldest: Int, totalSamples: Int, lastSentValid: Bool) -> Int {
        guard totalSamples > 0 else { return oldest % ringIndexModulo }
        
        // Bound all indices to valid range [0, ringIndexModulo)
        let boundedRequested = max(0, requested) % ringIndexModulo
        let boundedOldest = max(0, oldest) % ringIndexModulo
        
        // If device indicates last sync point is invalid (buffer wrapped), force restart from oldest
        if !lastSentValid {
            print("⚠️ Buffer has wrapped around (last_sent_valid=false); forcing restart from oldest index \(boundedOldest)")
            return boundedOldest
        }
        
        // Calculate the distance from oldest to requested (in circular buffer terms)
        // This accounts for wraparound: if oldest=45 and requested=5, distance=10 (wraps around)
        let distance = (boundedRequested - boundedOldest + ringIndexModulo) % ringIndexModulo
        
        // Check if requested index is within valid range [oldestIndex, oldestIndex + totalSamples)
        let isRequestedInValidRange = distance < totalSamples
        
        if isRequestedInValidRange {
            print("✅ Requested index \(boundedRequested) is valid: distance=\(distance) < totalSamples=\(totalSamples)")
            return boundedRequested
        } else {
            // Requested index is outside valid range, return oldest (start of valid data)
            print("⚠️ Requested index \(boundedRequested) is outside valid range [oldest=\(boundedOldest), end=\((boundedOldest + totalSamples - 1) % ringIndexModulo)]. Distance=\(distance) >= totalSamples=\(totalSamples). Using oldest index=\(boundedOldest)")
            return boundedOldest
        }
    }
    
    /// Log circular buffer state for debugging
    private func logCircularBufferState(oldest: Int, totalSamples: Int, requested: Int, effective: Int) {
        let boundedOldest = max(0, oldest) % ringIndexModulo
        let boundedRequested = max(0, requested) % ringIndexModulo
        let boundedEffective = max(0, effective) % ringIndexModulo
        
        let writeIndex = (boundedOldest + totalSamples) % ringIndexModulo
        let endIndex = (boundedOldest + totalSamples - 1) % ringIndexModulo
        let occupancy = Double(totalSamples) / Double(ringIndexModulo) * 100.0
        
        print("🔄 Circular Buffer State:")
        print("   Buffer size: \(ringIndexModulo) indices")
        print("   Occupancy: \(totalSamples) samples (\(String(format: "%.1f", occupancy))%)")
        print("   Valid range: [\(boundedOldest)....\(endIndex)] (oldest to newest)")
        print("   Write position (next): \(writeIndex)")
        print("   Requested start: \(boundedRequested)")
        print("   Effective start: \(boundedEffective)")
        
        if boundedEffective != boundedRequested {
            print("   ⚠️ Start index adjusted from \(boundedRequested) to \(boundedEffective)")
        }
    }
    
    /// Cancel an ongoing sync operation
    func cancelSync() {
        syncTimeoutTimer?.invalidate()
        syncTimeoutTimer = nil
        syncSessionContext = nil
        latestSyncedSampleDate = nil
        syncReceivedCount = 0
        
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
