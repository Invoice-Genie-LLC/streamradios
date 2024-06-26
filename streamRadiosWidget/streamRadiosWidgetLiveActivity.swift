//
//  streamRadiosWidgetAttributes.swift
//  streamRadiosWidget
//
//  Created by Kley Sulo on 6/10/24.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct streamRadiosWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }
    
    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct streamRadiosWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: streamRadiosWidgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)
            
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension streamRadiosWidgetAttributes {
    fileprivate static var preview: streamRadiosWidgetAttributes {
        streamRadiosWidgetAttributes(name: "World")
    }
}

extension streamRadiosWidgetAttributes.ContentState {
    fileprivate static var smiley: streamRadiosWidgetAttributes.ContentState {
        streamRadiosWidgetAttributes.ContentState(emoji: "😀")
    }
    
    fileprivate static var starEyes: streamRadiosWidgetAttributes.ContentState {
        streamRadiosWidgetAttributes.ContentState(emoji: "🤩")
    }
}

#Preview("Notification", as: .content, using: streamRadiosWidgetAttributes.preview) {
    streamRadiosWidgetLiveActivity()
} contentStates: {
    streamRadiosWidgetAttributes.ContentState.smiley
    streamRadiosWidgetAttributes.ContentState.starEyes
}
