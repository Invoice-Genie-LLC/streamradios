// RadioWidget.swift
// AlbRadioStreamWidgetExtension

import WidgetKit
import SwiftUI

struct RadioWidgetEntryView: View {
    var entry: SimpleEntry

    var body: some View {
        VStack {
            if let iconData = entry.stationIcon, let imageData = Data(base64Encoded: iconData), let image = UIImage(data: imageData) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 50, height: 50)
                    .cornerRadius(8)
            }
            Text(entry.stationName)
                .font(.headline)
                .padding(.top, 8)
            Text(entry.stationMetadata)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .padding()
    }
}

struct Provider: TimelineProvider {
    typealias Entry = SimpleEntry

    func placeholder(in context: Context) -> SimpleEntry {
        SimpleEntry(date: Date(), stationName: "Loading...", stationIcon: nil, stationMetadata: "Loading...")
    }

    func getSnapshot(in context: Context, completion: @escaping (SimpleEntry) -> Void) {
        let entry = SimpleEntry(date: Date(), stationName: "Station Name", stationIcon: nil, stationMetadata: "Station Metadata")
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SimpleEntry>) -> Void) {
        var entries: [SimpleEntry] = []

        let sharedDefaults = UserDefaults(suiteName: "group.your.bundle.identifier")
        let stationName = sharedDefaults?.string(forKey: "stationName") ?? "No Station"
        let stationIcon = sharedDefaults?.string(forKey: "stationIcon")
        let stationMetadata = sharedDefaults?.string(forKey: "stationMetadata") ?? "No Metadata"

        let currentDate = Date()
        let entry = SimpleEntry(date: currentDate, stationName: stationName, stationIcon: stationIcon, stationMetadata: stationMetadata)
        entries.append(entry)

        let timeline = Timeline(entries: entries, policy: .after(currentDate.addingTimeInterval(15 * 60)))
        completion(timeline)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let stationName: String
    let stationIcon: String?
    let stationMetadata: String
}

struct RadioWidget: Widget {
    let kind: String = "albRadioWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            RadioWidgetEntryView(entry: entry)
        }
        .configurationDisplayName("Radio Station")
        .description("Displays the current radio station and metadata.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct RadioWidget_Previews: PreviewProvider {
    static var previews: some View {
        RadioWidgetEntryView(entry: SimpleEntry(date: Date(), stationName: "Preview Station", stationIcon: nil, stationMetadata: "Preview Metadata"))
            .previewContext(WidgetPreviewContext(family: .systemSmall))
    }
}
