//
//  LyricsView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/23/24.
//

import SwiftUI
import Combine

struct LyricsView: View {
    var lyrics: String
    var title: String
    var artistName: String
    var onClose: () -> Void
    var getCurrentPlaybackTime: () -> TimeInterval
    
    @State private var lyricsArray: [(text: String, time: TimeInterval)] = []
    @State private var currentLine: Int = 0
    @State private var timer: AnyCancellable?
    @State private var currentTime: TimeInterval = 0.0
    @State private var isUserScrolling: Bool = false // Add state to track user interaction
    
    var body: some View {
        VStack {
            HStack {
                VStack(alignment: .leading) {
                    Text(title)
                        .font(.title)
                        .bold()
                        .foregroundColor(.white)
                    Text(artistName)
                        .font(.title2)
                        .foregroundColor(.gray)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundColor(.white)
                }
            }
            .padding()
            .background(Color.black)
            
            Divider() // Add a divider line under the title
                .background(Color.gray.opacity(0.5))
            
            GeometryReader { geometry in
                ScrollViewReader { scrollViewProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) { // Align VStack contents to the leading edge
                            ForEach(lyricsArray.indices, id: \.self) { index in
                                Text(lyricsArray[index].text)
                                    .font(.title2)
                                    .bold()
                                    .foregroundColor(Color.white.opacity(0.7))
                                    .frame(maxWidth: .infinity, alignment: .leading) // Align text to the left
                                    .padding(.vertical, 3)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal)
                        .frame(width: geometry.size.width)
                    }
                    .onAppear {
                        lyricsArray = parseLyrics(lyrics)
                        startLyricsSync(scrollViewProxy: scrollViewProxy)
                    }
                    .onDisappear {
                        stopLyricsSync()
                    }
                    .gesture(
                        DragGesture().onChanged { _ in
                            isUserScrolling = true
                        }.onEnded { _ in
                            isUserScrolling = false
                        }
                    )
                }
            }
        }
        .background(Color.black)
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func parseLyrics(_ lyrics: String) -> [(text: String, time: TimeInterval)] {
        let totalDuration: TimeInterval = 5 * 60 // Assume a total song duration of 5 minutes
        let lines = lyrics.components(separatedBy: "\n")
        let timeIncrement = totalDuration / TimeInterval(lines.count)
        
        return lines.enumerated().map { (index, line) in
            (text: line, time: TimeInterval(index) * timeIncrement)
        }
    }
    
    private func startLyricsSync(scrollViewProxy: ScrollViewProxy) {
        timer = Timer.publish(every: 0.1, on: .main, in: .common)
            .autoconnect()
            .sink { _ in
                updateCurrentTime()
                updateCurrentLine()
                if !isUserScrolling { // Check the flag before scrolling
                    withAnimation(.easeInOut(duration: 0.5)) {
                        scrollViewProxy.scrollTo(currentLine, anchor: .center)
                    }
                }
            }
    }
    
    private func stopLyricsSync() {
        timer?.cancel()
        timer = nil
    }
    
    private func updateCurrentTime() {
        currentTime = getCurrentPlaybackTime()
    }
    
    private func updateCurrentLine() {
        if let nextLine = lyricsArray.firstIndex(where: { $0.time > currentTime }) {
            currentLine = max(0, nextLine - 1)
        } else {
            currentLine = lyricsArray.count - 1
        }
    }
}

struct LyricsView_Previews: PreviewProvider {
    static var previews: some View {
        LyricsView(
            lyrics: "This is a sample lyric.\nIt should scroll smoothly.\nSyncing with the song playback.\nEnjoy the music!",
            title: "Sample Song",
            artistName: "Sample Artist",
            onClose: {},
            getCurrentPlaybackTime: { 0.0 }
        )
    }
}
