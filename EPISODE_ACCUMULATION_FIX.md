# Episode Accumulation Fix

## Problem
Episodes were accumulating when new episodes were fetched, resulting in more episodes being displayed than actually exist in the podcast feed.

## Root Cause
In the `performMinimalEpisodeSampling()` method (line ~2301), when new episodes were found, the code was **concatenating** the old snapshot episodes with new episodes:

```swift
// OLD CODE - CAUSED ACCUMULATION
let updatedEpisodes = (self.getEpisodeSnapshot(for: feedId) ?? []) + newEpisodes
```

This approach had several problems:
1. **Duplicates**: If the same episode appeared in both the snapshot and new episodes, it would be shown twice
2. **No Source of Truth**: Used cached snapshot instead of fresh Core Data
3. **Accumulation**: Episodes kept growing beyond the actual feed count

## Solution

### 1. Use Core Data as Source of Truth
Instead of concatenating, now we:
1. Add new episodes to Core Data (with deduplication)
2. Get the **complete fresh list** from Core Data
3. Display that complete list

```swift
// NEW CODE - PREVENTS ACCUMULATION
// Get fresh episode list from Core Data (source of truth) to avoid accumulation
let allEpisodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)
```

### 2. Add Deduplication Layer
Added an extra safety layer to deduplicate by episode ID:

```swift
// CRITICAL: Deduplicate episodes by ID to prevent accumulation
var seenIds = Set<String>()
let uniqueEpisodes = allEpisodes.filter { episode in
    if seenIds.contains(episode.id) {
        print("🚨 DEDUP: Removing duplicate episode \(episode.id)")
        return false
    }
    seenIds.insert(episode.id)
    return true
}
```

### 3. Respect Episode Limits
The `reconcileNewEpisodes()` method already enforces `maxEpisodes` limit:
- Adds only truly new episodes (deduplicates automatically)
- Enforces feed's episode limit
- Removes oldest episodes if over limit

## How It Works Now

### When New Episodes Are Detected:

1. **Parse RSS** (first 50 episodes only)
   ```
   Found: 3 new episodes
   ```

2. **Add to Core Data**
   ```
   reconcileNewEpisodes() checks for duplicates
   Adds only episodes with new IDs
   Enforces maxEpisodes limit (removes oldest if needed)
   ```

3. **Get Fresh List**
   ```
   getEpisodesForFeed() returns complete list from Core Data
   Total: 100 episodes (not 103!)
   ```

4. **Deduplicate**
   ```
   Filter by Set<String> of episode IDs
   Removes any duplicates (safety net)
   ```

5. **Update UI**
   ```
   Shows exactly 100 episodes
   Sorted by publication date (newest first)
   ```

## Benefits

### Before Fix:
- ❌ Episodes accumulated on each refresh
- ❌ Feed with 100 episodes could show 150+ episodes
- ❌ Duplicates could appear
- ❌ No respect for episode limits

### After Fix:
- ✅ Shows exact number of episodes in feed
- ✅ No accumulation on refresh
- ✅ Duplicates automatically removed
- ✅ Respects `maxEpisodes` limit
- ✅ Core Data is source of truth

## Code Changes

### File: `StreamRadios/ViewModels/PodcastViewModel.swift`

**Location**: `performMinimalEpisodeSampling()` method (around line 2299)

**Before**:
```swift
let updatedEpisodes = (self.getEpisodeSnapshot(for: feedId) ?? []) + newEpisodes
let sortedEpisodes = updatedEpisodes.sorted { $0.publicationDate > $1.publicationDate }
```

**After**:
```swift
// Get fresh episode list from Core Data (source of truth) to avoid accumulation
let allEpisodes = await PodcastCoreDataManager.shared.getEpisodesForFeed(feedId)

// CRITICAL: Deduplicate episodes by ID to prevent accumulation
var seenIds = Set<String>()
let uniqueEpisodes = allEpisodes.filter { episode in
    if seenIds.contains(episode.id) {
        print("🚨 DEDUP: Removing duplicate episode \(episode.id)")
        return false
    }
    seenIds.insert(episode.id)
    return true
}

let sortedEpisodes = uniqueEpisodes.sorted { $0.publicationDate > $1.publicationDate }
```

## Testing

### To Verify Fix:

1. **Check Initial Count**
   ```
   Open podcast feed
   Note episode count: e.g., 100 episodes
   ```

2. **Refresh Multiple Times**
   ```
   Pull to refresh 3-4 times
   Count should remain: 100 episodes (not growing)
   ```

3. **Monitor Console**
   ```
   Look for: "now showing X total episodes (added Y new)"
   X should stay constant if no new episodes
   X should grow only by actual new episodes
   ```

4. **Check for Duplicates**
   ```
   Scroll through list
   Should see: "🚨 DEDUP" if duplicates found
   UI should show: Each episode only once
   ```

## Edge Cases Handled

1. **No New Episodes**: Count stays the same ✅
2. **Some New Episodes**: Count increases by exact number of new episodes ✅
3. **Duplicates in Feed**: Automatically deduplicated ✅
4. **Episode Limit Exceeded**: Oldest episodes removed to maintain limit ✅
5. **Multiple Rapid Refreshes**: No accumulation ✅

## Summary

The fix ensures that:
- **Core Data** is the single source of truth
- **Deduplication** happens at multiple levels (Core Data + Display)
- **Episode limits** are enforced
- **No accumulation** occurs on refresh
- **Exact episode count** matches the feed

The app now correctly displays only the episodes that actually exist in the podcast feed, without any accumulation or duplication.
