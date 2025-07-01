//
//  ReconnectingIndicatorView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 8/14/24.
//

import SwiftUI

struct ReconnectingIndicatorView: View {
    let connectionState: ConnectionState
    let isAttemptingReconnection: Bool
    
    var body: some View {
        if shouldShowIndicator {
            HStack(spacing: 8) {
                // Connection status icon
                connectionIcon
                
                // Status text
                Text(statusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(statusColor)
                
                // Loading indicator for connecting states
                if showLoadingIndicator {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(statusColor)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(backgroundColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(statusColor.opacity(0.3), lineWidth: 1)
                    )
            )
            .animation(.easeInOut(duration: 0.3), value: connectionState)
        }
    }
    
    private var shouldShowIndicator: Bool {
        switch connectionState {
        case .connected:
            return false // Don't show indicator when connected
        case .connecting, .disconnected, .reconnecting:
            return true
        }
    }
    
    private var connectionIcon: some View {
        Group {
            switch connectionState {
            case .connected:
                Image(systemName: "wifi")
                    .foregroundColor(.green)
            case .connecting:
                Image(systemName: "wifi")
                    .foregroundColor(.orange)
            case .disconnected:
                Image(systemName: "wifi.slash")
                    .foregroundColor(.red)
            case .reconnecting:
                Image(systemName: "arrow.clockwise")
                    .foregroundColor(.orange)
                    .rotationEffect(.degrees(isAttemptingReconnection ? 360 : 0))
                    .animation(
                        isAttemptingReconnection ? 
                        Animation.linear(duration: 1.0).repeatForever(autoreverses: false) : 
                        .default, 
                        value: isAttemptingReconnection
                    )
            }
        }
        .font(.system(size: 14, weight: .medium))
    }
    
    private var statusText: String {
        switch connectionState {
        case .connected:
            return "Connected"
        case .connecting:
            return "Connecting..."
        case .disconnected:
            return "No connection"
        case .reconnecting:
            return "Reconnecting..."
        }
    }
    
    private var statusColor: Color {
        switch connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .red
        case .reconnecting:
            return .orange
        }
    }
    
    private var backgroundColor: Color {
        statusColor.opacity(0.1)
    }
    
    private var showLoadingIndicator: Bool {
        switch connectionState {
        case .connecting, .reconnecting:
            return true
        case .connected, .disconnected:
            return false
        }
    }
}
