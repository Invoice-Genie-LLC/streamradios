# Podcast Search Setup Guide

## Overview
The AddPodcastView now includes a search box that integrates with both PodcastIndex.org and Apple iTunes APIs to help users find podcasts easily.

## Required Setup

### 1. PodcastIndex.org API Secret
**IMPORTANT:** You need to complete the PodcastIndex.org API setup:

1. Go to: https://api.podcastindex.org/signup
2. Create a free developer account
3. Get your API SECRET (you already have the API KEY: `GXMPBQKYKCBRMQ5H7R75`)
4. Update the secret in `StreamRadios/ViewModels/PodcastSearchService.swift`:

```swift
private let podcastIndexAPISecret = "YOUR_ACTUAL_SECRET_HERE"
```

### 2. Files Added/Modified

#### Modified Files:
- `StreamRadios/AddPodcastView.swift` - Integrated complete podcast search functionality including:
  - Data models for both PodcastIndex.org and iTunes APIs
  - Search service with async/await support
  - Modern SwiftUI search interface
  - Error handling and loading states

## Features

### Search Functionality
- **Dual API Integration**: Searches both PodcastIndex.org and iTunes simultaneously
- **Duplicate Removal**: Automatically removes duplicate results based on feed URL
- **Debounced Search**: 500ms delay to prevent excessive API calls
- **Modern UI**: Consistent with the app's existing design system

### User Experience
- Real-time search as you type
- Loading indicators and error handling
- Podcast artwork display
- Source indicators (PodcastIndex vs iTunes)
- One-tap form population

### Credit Requirement
- Includes required attribution to PodcastIndex.org as per their terms
- Also credits Apple iTunes for completeness

## How It Works

1. User types in the search box
2. After 500ms delay, searches are triggered to both APIs
3. Results are combined and deduplicated
4. User can tap any result to populate the form fields
5. User can then add/save the podcast normally

## API Limitations

- **PodcastIndex.org**: Requires API key + secret, 50 results max per search
- **iTunes**: No authentication required, 50 results max per search
- Both APIs have rate limiting - the app handles this gracefully

## Testing

Once you add the PodcastIndex secret, you can test by:
1. Opening AddPodcastView
2. Typing in the search box (e.g., "This American Life")
3. Tapping on any result should populate the form fields
4. Proceed to add the podcast normally

## Next Steps

1. Get your PodcastIndex.org API secret
2. Update the `PodcastSearchService.swift` file
3. Test the functionality
4. The feature is ready to use! 