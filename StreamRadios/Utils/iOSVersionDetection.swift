//
//  iOSVersionDetection.swift
//  StreamRadios
//
//  Created by Assistant on 9/16/25.
//

import Foundation
import UIKit

/// Utility for detecting iOS version and enabling iOS 26+ specific features
struct iOSVersionDetection {
    
    /// Check if the current iOS version is 26.0 or higher
    static var isiOS26OrLater: Bool {
        if #available(iOS 26.0, *) {
            return true
        } else {
            return false
        }
    }
    
    /// Check if the current iOS version is exactly iOS 26
    static var isiOS26: Bool {
        if #available(iOS 26.0, *) {
            // Check if it's not iOS 27 or later
            if #available(iOS 27.0, *) {
                return false
            }
            return true
        } else {
            return false
        }
    }
    
    /// Get the current iOS version as a string
    static var currentiOSVersion: String {
        return UIDevice.current.systemVersion
    }
    
    /// Check if liquid glass effects should be enabled
    static var shouldEnableLiquidGlass: Bool {
        return isiOS26OrLater
    }
}
