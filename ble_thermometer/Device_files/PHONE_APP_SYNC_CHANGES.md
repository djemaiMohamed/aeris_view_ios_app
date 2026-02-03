# Air Quality Device - Simplified Sync Protocol

## Overview

The device firmware has been updated to use a **simplified, stateless sync protocol**. The phone app now handles all timestamp calculations, eliminating complexity and potential timestamp drift issues.

---

## Key Changes

### Before (Complex Protocol)
- Device maintained epoch synchronization state
- Device attempted to convert uptime to absolute timestamps
- Risk of timestamp misalignment if phone and device clocks drift
- Timestamps could become stale if sync occurred long after epoch was set
- Required careful epoch management on device

### After (Simplified Protocol)
- **Device only stores uptime** - no epoch tracking
- **Device sends uptime values** directly to phone
- **Phone calculates timestamps** using current device uptime
- Stateless: no epoch state to manage on device
- Eliminates timestamp staleness issues
- Each sync uses current phone time, guaranteeing correct timestamps

---

## Data Exchange Protocol

### 1. Phone Reads Device Status
**Characteristic:** `syncDataCharUUID`
**Operation:** Read

**Response (8 bytes):**
```
Bytes 0-1:   Total samples available (UInt16, little-endian)
Bytes 2-5:   Current device uptime (UInt32, little-endian) 
Bytes 6:     Sync running (0x00 = idle, 0x01 = running)
Byte 7:      Reserved
```

**Example:**
```
Response: [0xE8, 0x03, 0x2C, 0x0B, 0x00, 0x00, 0x00, 0x00]
          ╰─ Total: 1000 samples ╯ ╰─ Device uptime: 2860s ╯ Idle
```

### 2. Phone Sends Sync Request
**Characteristic:** `syncDataCharUUID`
**Operation:** Write with Response

**Request (4 bytes):**
```
Bytes 0-3:   Requested start index in device buffer (UInt32, little-endian)
```

**That's it!** No epoch needed.

**Example:**
```
Request: [0x64, 0x00, 0x00, 0x00]
         ╰─ Start index: 100 ╯
```

### 3. Device Sends Sync Start Frame
**Frame Type:** 0x02 (in Byte 10)
**Total:** 12 bytes

**Format:**
```
Bytes 0-1:   Total samples available (UInt16)
Bytes 2-3:   Oldest index in buffer (UInt16)
Bytes 4-5:   Write index (next position) (UInt16)
Byte 6:      Protocol version (0x01)
Bytes 7-9:   Reserved
Byte 10:     Frame type (0x02)
Byte 11:     Reserved
```

### 4. Device Sends Data Frames
**Frame Type:** 0x01 (in Byte 10)
**Total:** 12 bytes each

**Format:**
```
Bytes 0-3:   Device uptime when sample was collected (UInt32, little-endian)
Bytes 4-5:   CO2 level in PPM (UInt16)
Bytes 6-7:   Temperature in centi-degrees Celsius (Int16, signed)
             e.g., 2350 = 23.50°C
Bytes 8-9:   Humidity percentage (UInt16)
             e.g., 5500 = 55.00%
Byte 10:     Frame type (0x01)
Byte 11:     Battery level (0-100)
```

**Example:**
```
Frame:  [0x7C, 0x0B, 0x00, 0x00, 0x2C, 0x04, 0x6E, 0x09, 0x2C, 0x15, 0x01, 0x64]
        ╰─ Uptime: 2940s ╯  ╰─ CO2: 0x042C (1068 PPM) ╯
        ╰─ Temp: 0x096E (2414 = 24.14°C) ╯  ╰─ Humidity: 0x152C (5420 = 54.20%) ╯
        ╰─ Type: 0x01 ╯  ╰─ Battery: 100% ╯
```

### 5. Device Sends Sync Done Frame
**Frame Type:** 0x03 (in Byte 10)
**Total:** 12 bytes

**Format:**
```
Bytes 0-1:   Total samples sent (UInt16)
Bytes 2-11:  Reserved
Byte 10:     Frame type (0x03)
```

---

## Timestamp Calculation (Phone Side)

### Algorithm

When you receive a sample with uptime value from the device:

```swift
// When you read device status:
let deviceUptimeAtStatusRead = <uptime from read response>
let phoneCurrentTime = Date().timeIntervalSince1970  // Current Unix timestamp

// When you receive a data frame during sync:
let sampleUptimeSeconds = <uptime from data frame>
let deviceUptimeAtSync = <device uptime from SYNC_START frame or last known>

// Calculate how long ago the sample was collected:
let deviceUptimeNow = sync_data_get_device_uptime()  // Call device to get current uptime
let secondsElapsedSinceDeviceBoot = deviceUptimeNow
let secondsSinceSampleWasCollected = secondsElapsedSinceDeviceBoot - sampleUptimeSeconds

// Calculate the absolute timestamp:
let sampleAbsoluteTimestamp = phoneCurrentTime - secondsSinceSampleWasCollected

// Or more directly:
let sampleAbsoluteTimestamp = (phoneCurrentTime - currentDeviceUptime) + sampleUptime
```

### Implementation Pattern

```swift
// At start of sync session, record this:
let syncStartPhoneTime = Date().timeIntervalSince1970
let syncStartDeviceUptime = <device uptime from status read>

// For each sample received:
let deviceUptimeNowSeconds = <device uptime from SYNC_START or periodic reads>
let deviceTimeSinceBootSeconds = deviceUptimeNowSeconds
let sampleUptimeSeconds = <uptime from data frame>

// The phone's reference point:
// When device uptime was 0, phone time was: syncStartPhoneTime - syncStartDeviceUptime
// So for any sample at device uptime X:
let sampleTimestamp = (syncStartPhoneTime - syncStartDeviceUptime) + sampleUptimeSeconds

// Simplified:
let sampleTimestamp = syncStartPhoneTime - (syncStartDeviceUptime - sampleUptimeSeconds)
```

### Example Calculation

```
Device uptime at status read:    3600 seconds (1 hour)
Phone time at that moment:       1767938335 (Unix timestamp)
Phone's reference time (boot):   1767938335 - 3600 = 1767934735

Sample uptime from data frame:   100 seconds (collected very early)

Sample absolute timestamp:       1767934735 + 100 = 1767934835
                                 (collected at 1 hour from now, minus 3500 seconds)
```

### Why This Works

- **No device state needed:** Device doesn't track or store epoch
- **Always accurate:** Timestamp calculated at sync time using current phone time
- **Recovers from drift:** If there's any time drift, it's corrected at next sync
- **Simple math:** Just add uptime to the device's "epoch" (phone time - device uptime)

---

## Sync Flow Example

```
Phone                           Device
  |                               |
  |----(Read Status)----------->  | 
  |<-(sampleCount, uptime)------- |
  |
  |----(Write Index=100)--------->|  Sync Request
  |                          (4 bytes)
  |
  |<---(SYNC_START Frame)---------|  Metadata
  |      total=533, oldest=0, write=450
  |
  |<---(DATA Frame #1)------------|  Sample 100: uptime=2840
  |<---(DATA Frame #2)------------|  Sample 101: uptime=2847
  |<---(DATA Frame #3)------------|  Sample 102: uptime=2854
  |                              ...
  |<---(DATA Frame #N)------------|  Sample N: uptime=2940
  |
  |<---(SYNC_DONE Frame)---------|  Sync complete
  |      samples_sent=100
  |
```

---

## Migration Checklist for Phone App

- [ ] **Update sync request structure:**
  - Old: 8 bytes (epoch + index)
  - New: 4 bytes (index only)
  
- [ ] **Update status read handling:**
  - Old: Extract epoch + sample count
  - New: Extract device uptime + sample count
  - Store device uptime for timestamp calculations

- [ ] **Remove epoch tracking:**
  - Delete any `lastReceivedEpoch` variable
  - Delete epoch synchronization logic
  - Delete epoch-based timestamp validation

- [ ] **Implement timestamp calculation:**
  - Calculate device "boot epoch" = phone_time - device_uptime
  - For each sample: absolute_ts = boot_epoch + sample_uptime
  - No high-bit checking needed (no marker bits)

- [ ] **Update stale sample filtering:**
  - Old logic may have checked epoch validity
  - New logic: simply compare calculated timestamp to lastSyncTimestamp
  - Much simpler! No epoch state to manage

- [ ] **Update sync progress tracking:**
  - Samples are now indexed 0 to MAX_SAMPLES-1
  - Use index to resume incomplete syncs
  - No timestamp-based filtering on device side

- [ ] **Update UI/logging:**
  - Log uptime values instead of absolute timestamps during sync
  - Display actual timestamps after calculation
  - Clearer debug output: "Uptime 2850s → Timestamp 1767938000"

---

## Benefits of Simplified Protocol

| Aspect | Before | After |
|--------|--------|-------|
| **Device state** | Tracks epoch, validates times | Stateless, only uptime |
| **Sync request** | 8 bytes | 4 bytes (-50%) |
| **Time accuracy** | Depends on epoch freshness | Always current (phone time) |
| **Timestamp staleness** | Risk if sync delayed | Eliminated |
| **Device complexity** | High (epoch management) | Low (just uptime) |
| **Phone complexity** | Medium | High (but explicit) |
| **Clock drift recovery** | Requires re-sync | Automatic at next sync |
| **Debugging** | Epoch state confusion | Clear uptime → timestamp math |

---

## Backward Compatibility

- **Not compatible** with old device firmware
- **Requires device firmware update** to simplified protocol
- **Old phone app will not work** with new device
- Once upgraded, both app and firmware must use simplified protocol

---

## Testing Notes

### Test Case 1: Immediate Sync
```
Device boots, immediately syncs
- Device uptime: 10s
- Phone time: 1767938335
- Sample at uptime=5: timestamp = 1767938335 - 10 + 5 = 1767938330 ✓
```

### Test Case 2: Long Delay Before Sync
```
Device boots, runs 1 hour, then syncs
- Device uptime: 3600s
- Phone time: 1767942000 (1 hour later)
- Old sample at uptime=100: 
  - Calculation: 1767942000 - 3600 + 100 = 1767938500 ✓
  - This is correct: sampled at ~10 minutes after boot
```

### Test Case 3: Resumable Sync
```
First sync: get samples 0-99
Second sync: start from 100
- No epoch drift issues
- Simply resume from index 100
- Timestamps still correct
```

---

## Questions & Answers

**Q: What if device uptime wraps around?**
A: Device uptime is 32-bit seconds (max ~136 years), shouldn't wrap. Phone can handle larger uptime values if needed.

**Q: What if phone and device clocks differ?**
A: That's fine! The calculation `phone_time - device_uptime` gives you the correct "reference epoch" at that moment.

**Q: Can we sync again to get the same samples?**
A: Yes, but use the index, not timestamp. Requesting index 100 will always get the same sample regardless of time.

**Q: What about very old samples?**
A: If device has been running for days, old samples will have low uptime values. The calculation still works correctly.

---

## Summary

The simplified protocol shifts timestamp responsibility from the device to the phone:
- **Device:** Just store uptime, send samples with uptime
- **Phone:** Calculate timestamps using current time

This eliminates epoch synchronization complexity and makes timestamps always correct at sync time.
