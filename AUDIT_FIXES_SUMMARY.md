# Swift SDK OHTTP Audit Fixes: C-07 and C-09

## Summary

Fixed two security vulnerabilities in the Swift OHTTP transport:
- **C-07**: 400-retry logic vulnerable to substring match attacks
- **C-09**: Header stripping fails for alias URLs

## Changes Made

### C-07: 400-retry substring match vulnerability

**Problem**: The retry logic checked if error message contains "HTTP 400" string, which could be triggered by a hostile relay embedding "HTTP 400" in its response body (up to 200 bytes included in error message).

**Fix**:
1. Added new error case `httpStatusError(statusCode: Int, message: String)` to `OHTTPError` enum
2. Changed `httpPost()` to throw `httpStatusError` with actual HTTP status code
3. Changed retry logic to match on `statusCode == 400` instead of string matching

**Files changed**:
- `Sources/ZcashLightClientKit/Modules/Service/OHTTP/OHTTPHPKE.swift:253` - Added httpStatusError case
- `Sources/ZcashLightClientKit/Modules/Service/OHTTP/OHTTPTransport.swift:280-281` - Throw httpStatusError with statusCode
- `Sources/ZcashLightClientKit/Modules/Service/OHTTP/OHTTPTransport.swift:170` - Check statusCode == 400 (not string)

### C-09: Header stripping misses alias URLs

**Problem**: Header stripping was keyed on `proxyHost(for: url) != nil`, which checks if the URL needs rewriting. But the app passes already-rewritten alias URLs (e.g., `cmc.zodl.com`), so `proxyHost` returns nil and headers are not stripped.

**Fix**:
1. Added `needsHeaderStripping(host:)` helper method that checks if host is one of the alias hosts (values in `proxyHostMapping`)
2. Made check case-insensitive (lowercased comparison)
3. Updated both `SDKSynchronizer` and `SlipstreamSynchronizer` to use the new method

**Files changed**:
- `Sources/ZcashLightClientKit/Modules/Service/OHTTP/OHTTPEndpoints.swift:125-133` - Added needsHeaderStripping()
- `Sources/ZcashLightClientKit/Synchronizer/SDKSynchronizer.swift:1390` - Use needsHeaderStripping(host:)
- `Sources/ZcashLightClientKit/Slipstream/SlipstreamSynchronizer.swift:2841` - Use needsHeaderStripping(host:)

### Bonus fix: Percent-encoding handling (C-09 E-IOS-07)

**Problem**: Used `url.path` which is percent-decoded, losing special characters.

**Fix**: Use `URLComponents.percentEncodedPath` to preserve percent-encoding.

**Files changed**:
- `Sources/ZcashLightClientKit/Synchronizer/SDKSynchronizer.swift:1385-1386` - Use percentEncodedPath
- `Sources/ZcashLightClientKit/Slipstream/SlipstreamSynchronizer.swift:2836-2838` - Use percentEncodedPath

## Tests Added

Created `Tests/OfflineTests/OHTTPAuditFixTests.swift` with comprehensive tests:

### C-07 Tests:
1. `testRetryDoesNotTriggerOnBodyContainingHTTP400()` - Proves hostile relay with HTTP 500 + "HTTP 400" in body does NOT trigger retry
2. `testRetryTriggersOnRealHTTP400()` - Proves legitimate HTTP 400 DOES trigger retry with key refresh

### C-09 Tests:
1. `testHeaderStrippingForAliasHosts()` - Proves alias hosts (cmc.zodl.com, near.zodl.com, vote.zodl.com) have stripping enabled
2. `testHeaderStrippingIsCaseInsensitive()` - Proves case-insensitive matching
3. `testProxyHostLookupStillWorks()` - Proves original host→alias mapping still works

## Production Call Sites

### OHTTPTransport.roundTrip():
- `Sources/ZcashLightClientKit/Synchronizer/SDKSynchronizer.swift:1411`
- `Sources/ZcashLightClientKit/Modules/Service/OHTTP/OHTTPGRPCClient.swift:62,96`
- `Sources/ZcashLightClientKit/Slipstream/SlipstreamSynchronizer.swift:2859`

### httpRequestOverOHTTP():
- `Sources/ZcashLightClientKit/Synchronizer/ClosureSDKSynchronizer.swift:349`
- `Sources/ZcashLightClientKit/Synchronizer/CombineSDKSynchronizer.swift:342`

## Build & Test Instructions

**On macOS with Xcode**:
```bash
cd /path/to/zodl-swift-wallet-sdk-private
git checkout feature/ohttp-integration

# Build
swift build

# Run all tests
swift test

# Run only audit fix tests
swift test --filter OHTTPAuditFixTests

# Specific test
swift test --filter testRetryDoesNotTriggerOnBodyContainingHTTP400
```

## Verification Checklist

- [ ] Tests compile without errors
- [ ] `testRetryDoesNotTriggerOnBodyContainingHTTP400` PASSES (proves C-07 fix works)
- [ ] `testRetryTriggersOnRealHTTP400` PASSES (proves retry still works for legitimate 400)
- [ ] `testHeaderStrippingForAliasHosts` PASSES (proves C-09 fix works)
- [ ] `testHeaderStrippingIsCaseInsensitive` PASSES (proves case-insensitivity)
- [ ] All existing OHTTP tests still pass
- [ ] No AI attribution added (per user rule for private repos)

## Attack Scenarios Mitigated

### C-07 Attack (now blocked):
```
1. Hostile relay receives OHTTP request
2. Relay returns HTTP 500 with body: "Internal error: HTTP 400 from gateway"
3. BEFORE FIX: Client sees "HTTP 400" in message → refreshes key + retries (duplicate send)
4. AFTER FIX: Client sees statusCode=500 → throws error immediately (no retry)
```

### C-09 Attack (now blocked):
```
1. App calls API via OHTTP proxy with rewritten URL (cmc.zodl.com)
2. BEFORE FIX: proxyHost(for: cmc.zodl.com) returns nil → headers not stripped → secret sent to gateway
3. AFTER FIX: needsHeaderStripping("cmc.zodl.com") returns true → headers stripped before gateway
```

## Notes

- All changes are backward compatible (no public API changes)
- New error case `httpStatusError` is internal to OHTTP module
- `needsHeaderStripping()` is public but only used internally
- No changes to Rust code required
- No changes to Cargo.toml or build configuration
