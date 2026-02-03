# Simplified Sync Protocol - Quick Reference

## Device ➜ Phone (12-byte Frames)

### SYNC_START (Frame Type 0x02)
```
[Bytes 0-1] Total samples available (UInt16)
[Bytes 2-3] Oldest index (UInt16)
[Bytes 4-5] Write index/next position (UInt16)
[Byte 6]    Protocol version (0x01)
[Bytes 7-9] Reserved (0x00)
[Byte 10]   Frame type (0x02)
[Byte 11]   Reserved (0x00)
```

### DATA (Frame Type 0x01)
```
[Bytes 0-3] Sample uptime in seconds (UInt32) ← PHONE USES THIS FOR TIMESTAMP
[Bytes 4-5] CO2 in PPM (UInt16)
[Bytes 6-7] Temperature in centi-°C (Int16)
[Bytes 8-9] Humidity in percent (UInt16)
[Byte 10]   Frame type (0x01)
[Byte 11]   Battery percentage (0-100)
```

### SYNC_DONE (Frame Type 0x03)
```
[Bytes 0-1] Total samples sent (UInt16)
[Bytes 2-11] Reserved (0x00)
[Byte 10]   Frame type (0x03)
```

---

## Phone ➜ Device (Write Operations)

### Status Read (4 bytes response)
```
[Bytes 0-1] Sample count (UInt16)
[Bytes 2-5] Device uptime (UInt32) ← PHONE USES THIS
[Byte 6]    Sync running (0x00/0x01)
[Byte 7]    Reserved (0x00)
```

### Sync Request (4 bytes)
```
[Bytes 0-3] Start index (UInt32)
```

**That's it!** No epoch needed.

---

## Timestamp Calculation (One-Liner)

```
sampleTimestamp = currentPhoneTime - deviceUptimeNow + sampleUptimeFromFrame
```

Or with variables:
```
sampleTimestamp = (currentPhoneTime - currentDeviceUptime) + sampleUptime
```

---

## State Variables (Device)

### Keep These
- `write_index` - Next position to write (0-2999)
- `sample_count` - Total samples stored
- `oldest_index` - Oldest valid sample
- `sync_running` - Is sync active?

### Removed These
- ~~`epoch_actual`~~ → No longer needed
- ~~`epoch_valid`~~ → Always valid now

---

## State Variables (Phone)

### Add These
- `syncStartPhoneTime` - When sync started
- `syncStartDeviceUptime` - Device uptime at sync start
- `lastSyncIndex` - Resume point for next sync

### Remove These
- ~~`lastReceivedEpoch`~~ → Not used
- ~~`epochTimestamp`~~ → Not calculated

---

## Key Differences

| Old | New |
|-----|-----|
| Device: "Here's sample with epoch+uptime" | Device: "Here's sample at uptime 2850s" |
| Phone: Trust the timestamp | Phone: Calculate timestamp = phoneTime - deviceTime + sampleUptime |
| Sync req: 8 bytes | Sync req: 4 bytes |
| Timestamp conversion: Device side | Timestamp conversion: Phone side |
| Risk: Epoch drift | Risk: None (uses current phone time) |

---

## Sample Flow

```
Step 1: Phone reads status
  ← Device returns: count=533, uptime=4200, running=false

Step 2: Phone sends: startIndex=100 (4 bytes only)
  
Step 3: Device sends SYNC_START
  ← Metadata: total=533, oldest=0, write=450

Step 4: Device sends samples 100-N
  ← Each: uptime=4100, uptime=4107, uptime=4114, ...
  
Step 5: Phone calculates timestamps for each
  phone_time=1767938000, device_uptime=4200
  sample_uptime=4100 → timestamp = 1767938000 - 4200 + 4100 = 1767937900 ✓

Step 6: Device sends SYNC_DONE
  ← samples_sent=100
```

---

## Testing Checklist

- [ ] Device saves uptime (no high bit markers)
- [ ] Device sends index-based samples
- [ ] Phone receives 4-byte start index requests
- [ ] Phone gets device uptime from status read
- [ ] Phone calculates: `phoneTime - deviceUptime + sampleUptime`
- [ ] Timestamps are current (not stale)
- [ ] Sync can resume from saved index
- [ ] No timestamp high-bit stripping needed

---

## Common Mistakes to Avoid

❌ **Don't:** Send epoch in sync request
✅ **Do:** Send only the index (4 bytes)

❌ **Don't:** Check for 0x80000000 bit in uptime
✅ **Do:** Use uptime directly in calculation

❌ **Don't:** Store epoch on device
✅ **Do:** Let phone provide time at sync

❌ **Don't:** Use `epoch_actual + uptime`
✅ **Do:** Use `(phoneTime - deviceUptime) + sampleUptime`

---

## Why This Is Better

1. **Device is simple** - Just store uptime, no epoch management
2. **Phone has control** - Uses current time, always accurate
3. **Stateless** - No epoch synchronization issues
4. **Smaller messages** - 4 bytes instead of 8 for requests
5. **Works across device reboots** - Uptime resets, but phone handles it
6. **No drift** - Timestamps calculated fresh each sync
7. **Simpler code** - Less logic, fewer bugs
