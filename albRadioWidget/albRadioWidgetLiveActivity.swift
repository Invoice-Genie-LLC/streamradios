//
//  albRadioWidgetLiveActivity.swift
//  albRadioWidget
//
//  Created by Kley Sulo on 6/10/24.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct albRadioWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct albRadioWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: albRadioWidgetAttributes.self) { context in
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

extension albRadioWidgetAttributes {
    fileprivate static var preview: albRadioWidgetAttributes {
        albRadioWidgetAttributes(name: "World")
    }
}

extension albRadioWidgetAttributes.ContentState {
    fileprivate static var smiley: albRadioWidgetAttributes.ContentState {
        albRadioWidgetAttributes.ContentState(emoji: "😀")
     }

     fileprivate static var starEyes: albRadioWidgetAttributes.ContentState {
         albRadioWidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: albRadioWidgetAttributes.preview) {
   albRadioWidgetLiveActivity()
} contentStates: {
    albRadioWidgetAttributes.ContentState.smiley
    albRadioWidgetAttributes.ContentState.starEyes
}
