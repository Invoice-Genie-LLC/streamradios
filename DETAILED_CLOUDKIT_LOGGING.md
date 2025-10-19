# Detailed CloudKit Logging for "Fetching feeds from iCloud"

## Date: October 19, 2025

## Comprehensive Logging Added

Added extensive logging throughout the entire "Fetching feeds from iCloud" process to identify exactly where delays or holds might be occurring.

---

## Logging Points Added

### 1. **DataSyncManager - Comprehensive Sync Entry**
**File**: `DataSyncManager.swift` (Lines 2723-2740)

```swift
print("🔄 📻 Fetching ALL podcast feeds from CloudKit...")
print("🔍 DETAILED LOG: Setting podcastFeedsOperation to 'Fetching feeds from iCloud...'")
podcastFeedsOperation = "Fetching feeds from iCloud..."
podcastFeedsProgress = 0.1
print("🔍 DETAILED LOG: Set progress to 0.1, operation: '\(podcastFeedsOperation)'")

print("🔍 DETAILED LOG: About to call syncFromCloudKitWithRetry()...")
let syncStartTime = CFAbsoluteTimeGetCurrent()

let cloudKitFeeds = try await syncFromCloudKitWithRetry()

let syncEndTime = CFAbsoluteTimeGetCurrent()
let syncDuration = syncEndTime - syncStartTime
print("🔍 DETAILED LOG: syncFromCloudKitWithRetry() completed in \(String(format: "%.2f", syncDuration))s")
print("🔍 DETAILED LOG: Received \(cloudKitFeeds.count) feeds from CloudKit")
```

### 2. **DataSyncManager - Retry Method**
**File**: `DataSyncManager.swift` (Lines 1629-1641)

```swift
print("☁️ AF75B2 RESTORATION: Direct CloudKit sync without retries or timeouts")
print("🔍 DETAILED LOG: syncFromCloudKitWithRetry() - About to call PodcastCloudKitManager.shared.syncFromCloudKit()")

let cloudKitStartTime = CFAbsoluteTimeGetCurrent()

let feeds = try await PodcastCloudKitManager.shared.syncFromCloudKit()

let cloudKitEndTime = CFAbsoluteTimeGetCurrent()
let cloudKitDuration = cloudKitEndTime - cloudKitStartTime

print("✅ AF75B2 RESTORATION: CloudKit sync succeeded with \(feeds.count) feeds")
print("🔍 DETAILED LOG: PodcastCloudKitManager.syncFromCloudKit() took \(String(format: "%.2f", cloudKitDuration))s")
```

### 3. **PodcastCloudKitManager - Query Setup**
**File**: `PodcastCloudKitManager.swift` (Lines 2529-2535)

```swift
print("🔍 DETAILED LOG: PodcastCloudKitManager.syncFromCloudKit() - Creating CloudKit query")

let query = CKQuery(recordType: RecordType.podcastFeed, predicate: NSPredicate(value: true))
query.sortDescriptors = [NSSortDescriptor(key: "order", ascending: true)]
print("🔍 DETAILED LOG: Created query for recordType: \(RecordType.podcastFeed)")
print("🔍 DETAILED LOG: Query predicate: \(query.predicate)")
print("🔍 DETAILED LOG: Query sort descriptors: \(query.sortDescriptors ?? [])")
```

### 4. **PodcastCloudKitManager - CloudKit Query Execution**
**File**: `PodcastCloudKitManager.swift` (Lines 2538-2566)

```swift
print("🔍 DETAILED LOG: About to execute privateDatabase.records(matching: query)")

// Update progress to show CloudKit query is starting
Task { @MainActor in
    await DataSyncManager.shared.updatePodcastFeedProgress(
        currentCount: 0,
        totalCount: 1,
        progress: 0.15,
        operation: "Executing CloudKit query..."
    )
}

let queryStartTime = CFAbsoluteTimeGetCurrent()

let (matchResults, _) = try await privateDatabase.records(matching: query)

let queryTime = CFAbsoluteTimeGetCurrent() - queryStartTime
print("⚡ TIMING: CloudKit query completed in \(String(format: "%.2f", queryTime))s - found \(matchResults.count) records")
print("🔍 DETAILED LOG: CloudKit query returned \(matchResults.count) results")

// Update progress to show query completed
Task { @MainActor in
    await DataSyncManager.shared.updatePodcastFeedProgress(
        currentCount: 0,
        totalCount: matchResults.count,
        progress: 0.25,
        operation: "Processing \(matchResults.count) feed records..."
    )
}
```

### 5. **PodcastCloudKitManager - Record Parsing Loop**
**File**: `PodcastCloudKitManager.swift` (Lines 2572-2605)

```swift
for (index, (recordID, recordResult)) in matchResults.enumerated() {
    print("🔍 DETAILED LOG: Processing record \(index + 1)/\(matchResults.count) - ID: \(recordID.recordName)")
    
    // Update progress every record to show activity
    let progress = 0.25 + (Double(index) / Double(matchResults.count)) * 0.5 // 0.25 to 0.75
    Task { @MainActor in
        await DataSyncManager.shared.updatePodcastFeedProgress(
            currentCount: index,
            totalCount: matchResults.count,
            progress: progress,
            operation: "Processing feed \(index + 1)/\(matchResults.count)..."
        )
    }
    
    switch recordResult {
    case .success(let record):
        let recordParseStartTime = CFAbsoluteTimeGetCurrent()
        
        if let feed = try? await parsePodcastFeedRecord(record) {
            let recordParseTime = CFAbsoluteTimeGetCurrent() - recordParseStartTime
            feeds.append(feed)
            print("🔍 DETAILED LOG: ✅ Parsed feed '\(feed.title)' in \(String(format: "%.3f", recordParseTime))s")
        } else {
            let recordParseTime = CFAbsoluteTimeGetCurrent() - recordParseStartTime
            print("🔍 DETAILED LOG: ⚠️ Failed to parse record \(recordID.recordName) in \(String(format: "%.3f", recordParseTime))s")
        }
    case .failure(let error):
        print("🔍 DETAILED LOG: ❌ Record \(recordID.recordName) failed with error: \(error.localizedDescription)")
    }
}
```

### 6. **Fresh Install Path Logging**
**File**: `DataSyncManager.swift` (Lines 1692-1709)

```swift
print("🔍 DETAILED LOG: initializeCloudKitFeedsForFreshInstall - Setting operation to 'Checking iCloud...'")
podcastFeedsOperation = "Checking iCloud..."
podcastFeedsProgress = 0.2
print("🔍 DETAILED LOG: Set progress to 0.2, operation: '\(podcastFeedsOperation)'")

print("🔍 DETAILED LOG: About to call PodcastCloudKitManager.shared.syncFromCloudKit() from initializeCloudKitFeedsForFreshInstall")

let freshInstallSyncStartTime = CFAbsoluteTimeGetCurrent()

let feeds = try await PodcastCloudKitManager.shared.syncFromCloudKit()

let freshInstallSyncTime = CFAbsoluteTimeGetCurrent() - freshInstallSyncStartTime
print("🔍 DETAILED LOG: Fresh install CloudKit sync took \(String(format: "%.2f", freshInstallSyncTime))s")
```

### 7. **Progress Update Method**
**File**: `DataSyncManager.swift` (Lines 711-718)

```swift
@MainActor
func updatePodcastFeedProgress(currentCount: Int, totalCount: Int, progress: Double, operation: String) async {
    podcastFeedsCurrentCount = currentCount
    podcastFeedsTotalCount = totalCount
    podcastFeedsProgress = progress
    podcastFeedsOperation = operation
    print("🔍 PROGRESS UPDATE: Podcast feeds - \(currentCount)/\(totalCount) (\(Int(progress * 100))%) - \(operation)")
}
```

---

## What These Logs Will Show

### **Step-by-Step Visibility**

1. **Entry Point**: When "Fetching feeds from iCloud" starts
2. **Progress Updates**: Real-time progress shown in DataSyncProgressView
3. **CloudKit Query**: Exact timing of CloudKit database query
4. **Record Processing**: Individual record parsing with timing
5. **Completion**: Total time for entire operation

### **Performance Metrics**

- **Total sync time**: End-to-end timing
- **CloudKit query time**: Network request duration
- **Individual record parsing**: Per-record processing time
- **Progress updates**: Real-time activity in UI

### **Bottleneck Identification**

The logs will clearly show if the delay is in:
- **CloudKit query execution** (network/server delay)
- **Record parsing** (CPU-intensive processing)
- **Progress updates** (UI update delays)
- **Method transitions** (between different sync phases)

---

## Expected Log Output

For a user with 4 feeds, you should see:

```
🔍 DETAILED LOG: Setting podcastFeedsOperation to 'Fetching feeds from iCloud...'
🔍 DETAILED LOG: Set progress to 0.1, operation: 'Fetching feeds from iCloud...'
🔍 DETAILED LOG: About to call syncFromCloudKitWithRetry()...
🔍 DETAILED LOG: syncFromCloudKitWithRetry() - About to call PodcastCloudKitManager.shared.syncFromCloudKit()
🔍 DETAILED LOG: PodcastCloudKitManager.syncFromCloudKit() - Creating CloudKit query
🔍 DETAILED LOG: Created query for recordType: PodcastFeed
🔍 DETAILED LOG: About to execute privateDatabase.records(matching: query)
🔍 PROGRESS UPDATE: Podcast feeds - 0/1 (15%) - Executing CloudKit query...
⚡ TIMING: CloudKit query completed in 0.52s - found 4 records
🔍 DETAILED LOG: CloudKit query returned 4 results
🔍 PROGRESS UPDATE: Podcast feeds - 0/4 (25%) - Processing 4 feed records...
🔍 DETAILED LOG: Processing record 1/4 - ID: feed_123
🔍 PROGRESS UPDATE: Podcast feeds - 0/4 (25%) - Processing feed 1/4...
🔍 DETAILED LOG: ✅ Parsed feed 'My Podcast' in 0.003s
🔍 DETAILED LOG: Processing record 2/4 - ID: feed_456
🔍 PROGRESS UPDATE: Podcast feeds - 1/4 (37%) - Processing feed 2/4...
🔍 DETAILED LOG: ✅ Parsed feed 'Another Podcast' in 0.002s
...
⚡ TIMING: Total CloudKit sync completed in 0.60s
🔍 DETAILED LOG: syncFromCloudKitWithRetry() completed in 0.60s
🔍 DETAILED LOG: Received 4 feeds from CloudKit
```

---

## Troubleshooting Guide

### **If CloudKit Query is Slow**
- Look for long delay between "About to execute" and "query completed"
- Check network connectivity and CloudKit server status

### **If Record Parsing is Slow**
- Look for individual record parsing times > 1 second
- Check if artwork loading is still happening (should be skipped)

### **If Progress Updates Stop**
- Look for missing "PROGRESS UPDATE" logs
- Check if DataSyncProgressView is receiving updates

### **If No Activity is Reported**
- Look for gaps in the log sequence
- Check if any method calls are hanging without completion

---

## Build Status

✅ **BUILD SUCCEEDED** - Ready for testing

---

## Summary

Added comprehensive logging throughout the entire "Fetching feeds from iCloud" process:

### ✅ **Complete Visibility**
- **Entry/exit timing** for every method
- **Progress updates** sent to DataSyncProgressView
- **Individual record processing** with timing
- **CloudKit query execution** with detailed metrics

### ✅ **Real-Time Activity**
- **Progress updates** every record processed
- **Operation text changes** showing current activity
- **Percentage completion** visible in UI
- **Live timing information** in logs

### ✅ **Bottleneck Detection**
- **Precise timing** for each operation phase
- **Individual record timing** to find slow parsing
- **CloudKit query timing** to identify network delays
- **Method transition timing** to find gaps

**Result**: You'll now have complete visibility into exactly what's happening during "Fetching feeds from iCloud" and can identify any delays or holds in the process. The DataSyncProgressView will also show real-time activity instead of appearing stuck.
