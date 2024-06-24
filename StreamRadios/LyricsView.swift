
//
//  LyricsView.swift
//  StreamRadios
//
//  Created by Kley Sulo on 6/23/24.
//

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
    var onClose: () -> Void
    var getCurrentPlaybackTime: () -> TimeInterval
    
    @State private var lyricsArray: [(text: String, time: TimeInterval)] = []
    @State private var currentLine: Int = 0
    @State private var timer: AnyCancellable?
    @State private var currentTime: TimeInterval = 0.0
    
    var body: some View {
        VStack {
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title)
                        .foregroundColor(.white)
                }
            }
            .padding()

            GeometryReader { geometry in
                ScrollViewReader { scrollViewProxy in
                    ScrollView {
                        VStack(alignment: .center, spacing: 10) {
                            ForEach(lyricsArray.indices, id: \.self) { index in
                                Text(lyricsArray[index].text)
                                    .font(.title2)
                                    .bold()
                                    .foregroundColor(currentLine == index ? .yellow : .white)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 5)
                                    .id(index)
                            }
                        }
                        .padding(.horizontal)
                        .frame(width: geometry.size.width) // Adjust width based on GeometryReader
                    }
                    .onAppear {
                        lyricsArray = parseLyrics(lyrics)
                        startLyricsSync(scrollViewProxy: scrollViewProxy)
                    }
                    .onDisappear {
                        stopLyricsSync()
                    }
                }
            }
        }
        .background(LinearGradient(gradient: Gradient(colors: [.black, .gray]), startPoint: .top, endPoint: .bottom))
        .foregroundColor(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    
    private func parseLyrics(_ lyrics: String) -> [(text: String, time: TimeInterval)] {
        let totalDuration: TimeInterval = 5 * 60 // 5 minutes in seconds
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
                withAnimation(.easeInOut(duration: 0.5)) {
                    scrollViewProxy.scrollTo(currentLine, anchor: .center)
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
            onClose: {},
            getCurrentPlaybackTime: { 0.0 }
        )
    }
}
