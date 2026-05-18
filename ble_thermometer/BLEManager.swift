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
        // v2 protocol fields
        let totalSamples: Int
        let oldestSeqId: UInt32         // seq_id of oldest sample in device buffer
        let bootCount: Int              // Device boot generation at sync start
        let deviceUptimeAtSyncStart: UInt32
        let phoneTimeAtSyncStart: TimeInterval
        var samplesReceived: Int = 0
        var lastSeqIdReceived: UInt32 = 0
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
    @Published var connectingPeripheral: CBPeripheral? = nil
    @Published var connectionStatus: String = "Disconnected"
    @Published var airQualityLevel: AirQualityLevel = .excellent
    @Published var lastUpdateTime: Date = Date()
    @Published var batteryLevel: Int = 0 // Battery level percentage (0-100)
    @Published var calibrationInProgress: Bool = false
    @Published var calibrationFinished: Bool = false
    @Published var calibrationStatusMessage: String = ""
    
    // MARK: - Sync Properties
    @Published var syncState: SyncState = .idle
    @Published var lastSyncTimestamp: Date? = nil  // Persisted for display only (not used for dedup in v2)
    private var syncTimeoutTimer: Timer?
    private var syncReceivedCount: Int = 0
    private var lastSyncNotificationTime: Date?
    private let minimumSyncTimeout: TimeInterval = 180.0
    private let maximumSyncTimeout: TimeInterval = 900.0
    private let perSampleTimeoutAllowance: TimeInterval = 0.75
    private var currentSyncTimeoutInterval: TimeInterval?
    private var syncSessionContext: SyncSessionContext?
    private var latestSyncedSampleDate: Date?
    // v2: per-device monotonic seq_id tracking (keyed by device UUID string, persisted in UserDefaults)
    private var lastKnownSeqIdByDevice: [String: UInt32] = [:]
    
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
    private var syncNotifyRetryCount: [CBPeripheral: Int] = [:] // Retry counter for CCCD setup after pairing

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
        loadLastKnownSeqIds()
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
        characteristicNameCache[CBUUID(string: "2A1C")] = "Temperature Measurement"
        characteristicNameCache[CBUUID(string: "2A6F")] = "Humidity"
        characteristicNameCache[co2CharUUID] = "CO2 Measurement"
        characteristicNameCache[CBUUID(string: "2A19")] = "Battery Level"
        characteristicNameCache[CBUUID(string: "2A00")] = "Device Name"
        characteristicNameCache[calibrationCharUUID] = "CO2 Calibration"
        characteristicNameCache[syncDataCharUUID] = "Sync Data"
        characteristicNameCache[displayModeCharUUID] = "Display Mode"
        characteristicNameCache[measurementIntervalUUID] = "Measurement Interval"
        characteristicNameCache[tempUnitCharUUID] = "Temperature Unit"
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
        connectingPeripheral = peripheral
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
            self.connectingPeripheral = nil
            self.connectionStatus = "Connected"
            peripheral.discoverServices(nil) // discover all services to find custom calibration characteristic
            print("🔗 Connected to \(peripheral.name ?? "Unknown Device")")
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        DispatchQueue.main.async {
            self.connectedPeripheral = nil
            self.isConnecting = false
            self.connectingPeripheral = nil
            self.connectionStatus = "Disconnected"
            self.connectedPeripherals.removeAll { $0.identifier == peripheral.identifier }
            if self.activePeripheral?.identifier == peripheral.identifier {
                self.activePeripheral = self.connectedPeripherals.first
            }
            
            // Clean up completion handlers and CCCD retry state for this peripheral
            self.readValueCompletion.removeAll()
            self.syncDataNotificationsEnabled[peripheral] = false
            self.syncNotifyRetryCount[peripheral] = 0
            
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
            if characteristic.uuid == syncDataCharUUID {
                let attempt = (syncNotifyRetryCount[peripheral] ?? 0) + 1
                syncNotifyRetryCount[peripheral] = attempt
                // Retry up to 8 times at 3-second intervals (~24 s window).
                // This covers the typical passkey-entry time so at least one retry
                // fires after pairing completes and the CCCD write can succeed.
                if attempt <= 8 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                        guard let self = self, peripheral.state == .connected else { return }
                        guard self.syncDataNotificationsEnabled[peripheral] != true else { return }
                        print("🔄 Retrying CCCD setup for sync data (\(attempt)/8)")
                        peripheral.setNotifyValue(true, for: characteristic)
                    }
                }
            }
            return
        }
        
        if characteristic.uuid == syncDataCharUUID {
            if characteristic.isNotifying {
                print("✅ Sync data notifications successfully enabled")
                syncDataNotificationsEnabled[peripheral] = true
                syncNotifyRetryCount[peripheral] = 0  // stop further retries

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

    // MARK: Persistence helpers (per-device seq_id keyed by UUID)

    private func loadLastSyncTimestamp() {
        if let timestamp = UserDefaults.standard.object(forKey: "lastSyncTimestamp") as? Date {
            let minDate = Date(timeIntervalSince1970: 1577836800)
            let maxDate = Date().addingTimeInterval(86400)
            if timestamp >= minDate && timestamp <= maxDate {
                lastSyncTimestamp = timestamp
            } else {
                UserDefaults.standard.removeObject(forKey: "lastSyncTimestamp")
            }
        }
    }

    private func saveLastSyncTimestamp(_ timestamp: Date) {
        lastSyncTimestamp = timestamp
        UserDefaults.standard.set(timestamp, forKey: "lastSyncTimestamp")
    }

    func resetLastSyncTimestamp() {
        UserDefaults.standard.removeObject(forKey: "lastSyncTimestamp")
        lastSyncTimestamp = nil
    }

    private func loadLastKnownSeqIds() {
        if let stored = UserDefaults.standard.dictionary(forKey: "lastKnownSeqIds") as? [String: Int] {
            for (uuid, raw) in stored {
                lastKnownSeqIdByDevice[uuid] = UInt32(bitPattern: Int32(raw))
            }
        }
    }

    private func saveLastKnownSeqId(_ seqId: UInt32, for deviceId: String) {
        lastKnownSeqIdByDevice[deviceId] = seqId
        var stored = (UserDefaults.standard.dictionary(forKey: "lastKnownSeqIds") as? [String: Int]) ?? [:]
        stored[deviceId] = Int(Int32(bitPattern: seqId))
        UserDefaults.standard.set(stored, forKey: "lastKnownSeqIds")
    }

    private func lastKnownSeqId(for deviceId: String) -> UInt32 {
        return lastKnownSeqIdByDevice[deviceId] ?? UInt32.max  // UInt32.max = full-sync sentinel
    }

    /// Force a full resync for a specific device on next sync request.
    func resetSyncState(for peripheral: CBPeripheral) {
        let id = peripheral.identifier.uuidString
        lastKnownSeqIdByDevice.removeValue(forKey: id)
        var stored = (UserDefaults.standard.dictionary(forKey: "lastKnownSeqIds") as? [String: Int]) ?? [:]
        stored.removeValue(forKey: id)
        UserDefaults.standard.set(stored, forKey: "lastKnownSeqIds")
    }

    // MARK: Sync request

    func requestSyncData(lastSync: Date? = nil) {
        _ = lastSync
        let target = activePeripheral ?? connectedPeripheral
        guard let peripheral = target, peripheral.state == .connected else {
            DispatchQueue.main.async { self.syncState = .failed(message: "No connected device") }
            return
        }
        guard syncDataNotificationsEnabled[peripheral] == true else {
            if let services = peripheral.services {
                for service in services {
                    guard let chars = service.characteristics else { continue }
                    for c in chars where c.uuid == syncDataCharUUID {
                        peripheral.setNotifyValue(true, for: c)
                    }
                }
            }
            DispatchQueue.main.async {
                self.syncState = .failed(message: "Sync channel not ready — please retry in a moment")
            }
            return
        }

        syncSessionContext = nil
        latestSyncedSampleDate = nil
        syncTimeoutTimer?.invalidate()

        guard let services = peripheral.services else {
            DispatchQueue.main.async { self.syncState = .failed(message: "Services not discovered") }
            return
        }
        for service in services {
            guard let chars = service.characteristics else { continue }
            for char in chars where char.uuid == syncDataCharUUID {
                let seqId = lastKnownSeqId(for: peripheral.identifier.uuidString)
                let payload = encodeSyncDataRequest(lastKnownSeqId: seqId)
                DispatchQueue.main.async {
                    self.syncReceivedCount = 0
                    self.syncState = .syncing(progress: 0, receivedCount: 0)
                    self.lastSyncNotificationTime = Date()
                }
                writeValue(for: char, of: peripheral, value: payload)
                print("📤 Sync request sent (lastKnownSeqId=\(seqId == UInt32.max ? "FULL" : "\(seqId)"))")
                startSyncTimeoutTimer(totalSamples: nil)
                return
            }
        }
        DispatchQueue.main.async { self.syncState = .failed(message: "Sync characteristic not found") }
    }

    /// v2 sync request — 8 bytes: last_known_seq_id (UInt32 LE) + 4 reserved bytes
    private func encodeSyncDataRequest(lastKnownSeqId: UInt32) -> Data {
        var data = Data(count: 8)
        data[0] = UInt8(lastKnownSeqId & 0xFF)
        data[1] = UInt8((lastKnownSeqId >> 8) & 0xFF)
        data[2] = UInt8((lastKnownSeqId >> 16) & 0xFF)
        data[3] = UInt8((lastKnownSeqId >> 24) & 0xFF)
        // bytes 4-7 reserved, already 0
        return data
    }

    // MARK: Frame dispatch

    /// Handle notifications/indications on the sync_data characteristic
    private func handleSyncDataNotification(data: Data, peripheral: CBPeripheral) {
        guard data.count == 20 else {
            print("⚠️ Unexpected sync frame length: \(data.count) (expected 20)")
            return
        }
        guard let frameType = SyncFrameType(rawValue: data[14]) else {
            print("⚠️ Unknown frame type byte: \(data[14])")
            return
        }
        switch frameType {
        case .syncStart:
            handleSyncStart(data: data, peripheral: peripheral)
        case .syncData:
            handleSyncDataFrame(data: data, peripheral: peripheral)
        case .syncDone:
            let (samplesSent, lastSeqId) = decodeSyncDoneFrame(from: data)
            print("🏁 SYNC_DONE: samplesSent=\(samplesSent) lastSeqId=\(lastSeqId)")
            completeSyncOperation(reason: .done(samplesSent: samplesSent), lastSeqId: lastSeqId, peripheral: peripheral)
        case .syncAbort:
            let (samplesSent, lastSeqId, reason) = decodeSyncAbortFrame(from: data)
            print("🛑 SYNC_ABORT: samplesSent=\(samplesSent) lastSeqId=\(lastSeqId) reason=\(reason)")
            completeSyncOperation(reason: .abort(samplesSent: samplesSent, reason: reason), lastSeqId: lastSeqId, peripheral: peripheral)
        case .live:
            guard let sample = decodeMeasurementFrame(from: data, frameType: .live) else { return }
            updateLiveValues(from: sample, peripheral: peripheral)
            saveSensorReading(peripheral: peripheral)
        }
    }

    // MARK: Frame handlers

    private func handleSyncStart(data: Data, peripheral: CBPeripheral) {
        guard let startFrame = decodeSyncStartFrame(from: data) else { return }
        let phoneTimeNow = Date().timeIntervalSince1970
        syncSessionContext = SyncSessionContext(
            totalSamples: startFrame.totalSamples,
            oldestSeqId: startFrame.oldestSeqId,
            bootCount: startFrame.bootCount,
            deviceUptimeAtSyncStart: startFrame.deviceUptime,
            phoneTimeAtSyncStart: phoneTimeNow
        )
        syncReceivedCount = 0
        latestSyncedSampleDate = nil
        lastSyncNotificationTime = Date()
        DispatchQueue.main.async { self.syncState = .syncing(progress: 0, receivedCount: 0) }
        startSyncTimeoutTimer(totalSamples: startFrame.totalSamples)
        let bootEpoch = Int(phoneTimeNow) - Int(startFrame.deviceUptime)
        print("🚦 SYNC_START: total=\(startFrame.totalSamples) oldestSeq=\(startFrame.oldestSeqId) boot=\(startFrame.bootCount) bootEpoch≈\(bootEpoch)")
    }

    private func handleSyncDataFrame(data: Data, peripheral: CBPeripheral) {
        guard let session = syncSessionContext else {
            print("⚠️ DATA frame without active session")
            return
        }
        guard let sample = decodeMeasurementFrame(from: data, frameType: .syncData) else { return }

        // v2 deduplication: skip if we already have this (deviceId, seqId) pair
        if sample.sequenceId > 0, isDuplicate(seqId: sample.sequenceId, deviceId: peripheral.identifier.uuidString) {
            print("⏭️ Duplicate seq=\(sample.sequenceId) — skipping")
            lastSyncNotificationTime = Date()
            startSyncTimeoutTimer(totalSamples: session.totalSamples)
            return
        }

        syncReceivedCount += 1
        var updated = session
        updated.samplesReceived += 1
        updated.lastSeqIdReceived = sample.sequenceId
        syncSessionContext = updated
        latestSyncedSampleDate = max(latestSyncedSampleDate ?? sample.timestamp, sample.timestamp)
        publishSyncProgress()
        saveHistoricalSample(sample, peripheral: peripheral)

        lastSyncNotificationTime = Date()
        startSyncTimeoutTimer(totalSamples: session.totalSamples)
        print("⬇️ seq=\(sample.sequenceId) co2=\(sample.co2) t=\(sample.temperatureCentiDegrees) h=\(sample.humidity) bat=\(sample.battery)")
    }

    // MARK: Frame decoders (v2, 20-byte frames; frame type at byte 14)

    private func decodeSyncStartFrame(from data: Data) -> (totalSamples: Int, oldestSeqId: UInt32, bootCount: Int, deviceUptime: UInt32)? {
        guard data.count == 20 else { return nil }
        // [0-3]  device_uptime
        // [4-7]  oldest_seq_id
        // [8-9]  total_samples
        // [10-11] oldest_index (ignored by phone)
        // [12-13] boot_count
        // [14]   FRAME_SYNC_START
        let deviceUptime = UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
        let oldestSeqId  = UInt32(data[4]) | (UInt32(data[5]) << 8) | (UInt32(data[6]) << 16) | (UInt32(data[7]) << 24)
        let totalSamples = Int(UInt16(data[8]) | (UInt16(data[9]) << 8))
        let bootCount    = Int(UInt16(data[12]) | (UInt16(data[13]) << 8))
        return (totalSamples, oldestSeqId, bootCount, deviceUptime)
    }

    private func decodeSyncDoneFrame(from data: Data) -> (samplesSent: Int, lastSeqId: UInt32) {
        guard data.count >= 6 else { return (syncReceivedCount, 0) }
        let samplesSent = Int(UInt16(data[0]) | (UInt16(data[1]) << 8))
        let lastSeqId   = UInt32(data[2]) | (UInt32(data[3]) << 8) | (UInt32(data[4]) << 16) | (UInt32(data[5]) << 24)
        return (samplesSent, lastSeqId)
    }

    private func decodeSyncAbortFrame(from data: Data) -> (samplesSent: Int, lastSeqId: UInt32, reason: String) {
        guard data.count >= 15 else { return (syncReceivedCount, 0, "Unknown") }
        let samplesSent = Int(UInt16(data[0]) | (UInt16(data[1]) << 8))
        let lastSeqId   = UInt32(data[2]) | (UInt32(data[3]) << 8) | (UInt32(data[4]) << 16) | (UInt32(data[5]) << 24)
        let reasonCode  = data[13]
        let reason      = reasonCode == 1 ? "Generic abort" : "Abort code \(reasonCode)"
        return (samplesSent, lastSeqId, reason)
    }

    /// Decode a DATA or LIVE frame (v2, 20 bytes).
    /// DATA  [0-3] seq_id  [4-7] uptime  [8-9] co2  [10-11] temp  [12-13] hum  [14] type  [15] bat  [16-17] boot
    /// LIVE  same layout; seq_id=0 for live (not used for dedup)
    private func decodeMeasurementFrame(from data: Data, frameType: SyncFrameType) -> SensorSample? {
        guard data.count == 20 else {
            print("⚠️ Measurement frame wrong length: \(data.count)")
            return nil
        }
        let seqId    = UInt32(data[0]) | (UInt32(data[1]) << 8) | (UInt32(data[2]) << 16) | (UInt32(data[3]) << 24)
        let uptime   = UInt32(data[4]) | (UInt32(data[5]) << 8) | (UInt32(data[6]) << 16) | (UInt32(data[7]) << 24)
        let co2      = Int(UInt16(data[8])  | (UInt16(data[9]) << 8))
        let temp     = Int(Int16(bitPattern: UInt16(data[10]) | (UInt16(data[11]) << 8)))
        let humidity = Int(UInt16(data[12]) | (UInt16(data[13]) << 8))
        let battery  = Int(data[15])
        let boot     = Int(UInt16(data[16]) | (UInt16(data[17]) << 8))

        // Reconstruct absolute timestamp: bootEpoch + sampleUptime
        let timestamp: TimeInterval
        if let session = syncSessionContext, frameType == .syncData {
            let bootEpoch = session.phoneTimeAtSyncStart - TimeInterval(session.deviceUptimeAtSyncStart)
            timestamp = bootEpoch + TimeInterval(uptime)
        } else {
            // Live frame: use current phone time directly
            timestamp = Date().timeIntervalSince1970
        }
        return SensorSample(
            timestamp: Date(timeIntervalSince1970: timestamp),
            co2: co2,
            temperatureCentiDegrees: temp,
            humidity: humidity,
            battery: battery,
            frameType: frameType,
            sequenceId: seqId,
            bootCount: boot
        )
    }

    // MARK: Database helpers

    /// Returns true if a SensorReading with this (deviceId, seqId) already exists in the DB.
    private func isDuplicate(seqId: UInt32, deviceId: String) -> Bool {
        guard let context = modelContext, seqId > 0 else { return false }
        let seqIdInt = Int64(seqId)
        let request = FetchDescriptor<SensorReading>(
            predicate: #Predicate<SensorReading> { r in
                r.deviceId == deviceId && r.sequenceId == seqIdInt
            }
        )
        return (try? context.fetchCount(request) ?? 0) ?? 0 > 0
    }

    private func saveHistoricalSample(_ sample: SensorSample, peripheral: CBPeripheral) {
        guard let context = modelContext else { return }
        let reading = sample.toSensorReading(
            deviceId: peripheral.identifier.uuidString,
            deviceName: displayName(for: peripheral)
        )
        context.insert(reading)
        if syncReceivedCount % 50 == 0 {
            do {
                try context.save()
                print("💾 Saved \(syncReceivedCount) historical readings")
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
    
    private func handleSyncTimeout() {
        guard syncTimeoutTimer != nil else { return }
        syncTimeoutTimer?.invalidate()
        syncTimeoutTimer = nil
        completeSyncOperation(reason: .timeout, peripheral: activePeripheral ?? connectedPeripheral)
    }
    
    private func completeSyncOperation(reason: SyncCompletionReason,
                                        lastSeqId: UInt32 = 0,
                                        peripheral: CBPeripheral? = nil) {
        guard syncState.isSyncing else { return }

        syncTimeoutTimer?.invalidate()
        syncTimeoutTimer = nil

        if let context = modelContext { try? context.save() }

        let reported = syncSessionContext?.samplesReceived ?? syncReceivedCount
        let sessionLastSeq = syncSessionContext?.lastSeqIdReceived ?? lastSeqId
        let finalSeqId = max(lastSeqId, sessionLastSeq)

        let totalReceived: Int
        var finalState: SyncState

        switch reason {
        case .done(let samplesSent):
            totalReceived = max(samplesSent, reported)
            finalState = .completed(totalReceived: totalReceived)
            // Persist the highest confirmed seq_id so the next sync resumes correctly
            if finalSeqId > 0, let p = peripheral ?? activePeripheral ?? connectedPeripheral {
                saveLastKnownSeqId(finalSeqId, for: p.identifier.uuidString)
                print("✅ Sync done: \(totalReceived) samples, lastSeqId=\(finalSeqId)")
            }
            if let date = latestSyncedSampleDate { saveLastSyncTimestamp(date) }
        case .abort(let samplesSent, let reasonText):
            totalReceived = max(samplesSent, reported)
            finalState = .failed(message: "Sync aborted: \(reasonText). Partial data saved; please retry.")
            // Persist partial progress so the next sync doesn't re-download what we got
            if finalSeqId > 0, let p = peripheral ?? activePeripheral ?? connectedPeripheral {
                saveLastKnownSeqId(finalSeqId, for: p.identifier.uuidString)
                print("⚠️ Sync aborted after \(totalReceived) samples, lastSeqId=\(finalSeqId)")
            }
        case .timeout:
            totalReceived = reported
            finalState = .failed(message: "No response from device. Partial data saved; please retry.")
            if finalSeqId > 0, let p = peripheral ?? activePeripheral ?? connectedPeripheral {
                saveLastKnownSeqId(finalSeqId, for: p.identifier.uuidString)
            }
            print("⚠️ Sync timeout after \(totalReceived) samples")
        }

        DispatchQueue.main.async { self.syncState = finalState }
        syncSessionContext = nil
        latestSyncedSampleDate = nil
        currentSyncTimeoutInterval = nil
    }

    private func publishSyncProgress() {
        let total = syncSessionContext?.totalSamples ?? 0
        let progress = total > 0 ? min(Double(syncReceivedCount) / Double(total), 1.0) : 0
        DispatchQueue.main.async {
            self.syncState = .syncing(progress: progress, receivedCount: self.syncReceivedCount)
        }
    }

    func cancelSync() {
        syncTimeoutTimer?.invalidate()
        syncTimeoutTimer = nil
        syncSessionContext = nil
        latestSyncedSampleDate = nil
        syncReceivedCount = 0
        DispatchQueue.main.async { self.syncState = .idle }
        print("🛑 Sync cancelled")
    }
    
    /// Check if sync is currently in progress
    var isSyncing: Bool {
        return syncState.isSyncing
    }
}
