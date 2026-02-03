# Sync Recent Data - BLE Protocol Flow

When "Sync Recent Data" is requested from the History View, here's the complete BLE data exchange:

## 1. APP SENDS SYNC REQUEST (8 bytes)
**Characteristic:** `syncDataCharUUID` (475f3487-c251-4fbe-b006-37eba1d6c42e)
**Type:** Write with Response

### Request Format (all little-endian):
- **Bytes 0-3:** Current Unix timestamp (UInt32)
- **Bytes 4-7:** Requested start index in device's ring buffer (UInt32)

### Example:
```
App sends: [0x4C, 0x9C, 0x6F, 0x67, 0x00, 0x10, 0x00, 0x00]
           ╰─ Timestamp: 0x676F9C4C ╯   ╰─ Start Index: 0x1000 ╯
```

**What happens:**
- `requestedSyncStartIndex` is loaded from `UserDefaults` (persisted from previous sync)
- For "Sync Recent Data": uses the saved start index where last sync ended
- For "Request All Data": index is reset to 0 via `resetLastSyncTimestamp()`
- Current device time is included so device can validate the request

---

## 2. DEVICE RESPONDS WITH SYNC START FRAME (12 bytes)
**Frame Type:** 0x02 (syncStart)

### Response Format (all little-endian):
- **Bytes 0-1:** Total samples available in device buffer (UInt16)
- **Bytes 2-3:** Oldest index in ring buffer (UInt16)
- **Bytes 4-5:** Write index (next position to write) (UInt16)
- **Byte 6:** Protocol version (currently 0x01)
- **Bytes 7-11:** Reserved/padding

### Example:
```
Device sends: [0xE8, 0x03, 0x00, 0x00, 0xE8, 0x03, 0x01, 0x00, 0x00, 0x00, 0x02, 0x00]
              ╰─ Total: 1000 ╯  ╰─ Oldest: 0 ╯  ╰─ Write: 1000 ╯  ╰─ Proto: 0x01
```

**What happens:**
- App receives buffer state: how many samples exist, where they start, where device writes next
- App validates protocol version (must be 0x01)
- App calculates `effectiveStartIndex` = requested index, clamped to valid device window
- Creates `SyncSessionContext` to track this sync session

---

## 3. DEVICE SENDS MEASUREMENT FRAMES (12 bytes each)
**Frame Type:** 0x01 (syncData)

### Data Frame Format (all little-endian):
- **Bytes 0-3:** Unix timestamp of measurement (UInt32)
- **Bytes 4-5:** CO2 level in PPM (UInt16)
- **Bytes 6-7:** Temperature in centi-degrees Celsius (Int16, signed)
  - e.g., 2350 = 23.50°C
- **Bytes 8-9:** Humidity percentage (UInt16)
  - e.g., 5500 = 55.00%
- **Byte 10:** Frame type indicator (0x01 for syncData)
- **Byte 11:** Battery level percentage (0-100, UInt8)

### Example:
```
Device sends: [0x2D, 0x97, 0x6F, 0x67, 0x2C, 0x04, 0x6E, 0x09, 0x2C, 0x15, 0x01, 0x64]
              ╰─ Timestamp: 0x676F972D ╯  ╰─ CO2: 0x042C (1068 PPM) ╯
              ╰─ Temp: 0x096E (2414 = 24.14°C) ╯  ╰─ Humidity: 0x152C (5420 = 54.20%) ╯
              ╰─ Type: 0x01 ╯  ╰─ Battery: 100% ╯
```

**What happens:**
- App receives each historical sample
- Decodes all fields from bytes
- Filters out stale samples (older than last sync timestamp)
- Saves to local database in batches (every 50 samples)
- Updates sync progress UI
- Saves rolling start index to UserDefaults for resumable syncs
- Restarts timeout timer on each frame

---

## 4. DEVICE SENDS SYNC DONE FRAME (12 bytes)
**Frame Type:** 0x03 (syncDone)

### Format:
- **Bytes 0-1:** Total samples sent by device (UInt16)
- **Bytes 2-11:** Reserved

### Example:
```
Device sends: [0x64, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00]
              ╰─ Samples sent: 100 ╯                                         ╰─ Type: 0x03 ╯
```

**What happens:**
- Sync session is completed
- App calculates next start index: `(effectiveStart + totalReceived) % 65536`
- Saves next index to UserDefaults for next incremental sync
- Saves last sync timestamp
- Final database save
- Updates UI to "Sync Complete"

---

## 5. ALTERNATIVE: DEVICE SENDS SYNC ABORT FRAME (12 bytes)
**Frame Type:** 0x04 (syncAbort)

### Format:
- **Bytes 0-1:** Samples sent before abort (UInt16)
- **Bytes 2-5:** Reserved
- **Byte 6:** Abort reason code
  - 0x01 = Generic abort
- **Bytes 7-11:** Reserved

**What happens:**
- Sync is terminated abnormally
- Partial data (if any) is kept
- Next start index is updated based on samples received before abort
- User can retry sync

---

## Key Variables in BLEManager

| Variable | Purpose |
|----------|---------|
| `lastSyncStartIndex` | Persisted start index for incremental syncs |
| `requestedSyncStartIndex` | Start index sent in current request |
| `effectiveStartIndex` | Resolved start (requested clamped to valid window) |
| `syncReceivedCount` | Counter of samples received in current sync |
| `syncSessionContext` | Holds metadata about active sync session |
| `latestSyncedSampleDate` | Timestamp of most recent sample in this sync |

---

## Sync Completion Logic

### For "Sync Recent Data":
1. Load `lastSyncStartIndex` from UserDefaults (where last sync ended)
2. Send to device → get recent samples from that point onward
3. Save next index = `(start + received) % 65536`

### For "Request All Data":
1. Reset `lastSyncStartIndex` to 0 (via `resetLastSyncTimestamp()`)
2. Send 0 as start index → get all samples from oldest available
3. Save next index = total samples received (wraps at 65536)

---

## Timeouts

- **Dynamic timeout calculation:** `min(max(samples * 0.75 sec, 180 sec), 900 sec)`
- Restarted on each frame received
- If no frames received for timeout period → sync fails
- Partial data retained on timeout; can retry to resume

---

## Data Validation

- Stale samples (older than `lastSyncTimestamp`) are skipped
- Protects against re-downloading old data
- Only new samples update the saved timestamp

