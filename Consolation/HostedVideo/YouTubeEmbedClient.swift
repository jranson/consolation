//
//  YouTubeEmbedClient.swift
//  Consolation
//
//  Speaks to YouTube's embedded player: the IFrame Player API, the route Google supports and App Review accepts,
//  through YouTubePlayerKit (MIT). No stream extraction. Mac, iPad and iPhone only; Apple TV has no WebKit.
//
//  Privacy: each video gets its own website data store that is never written to disk, so no YouTube cookies or
//  storage outlive the player. (YouTube's privacy-enhanced youtube-nocookie.com host can't be used: YouTubePlayerKit
//  lets only youtube.com/embed load in its web view and sends any other address to the browser.) Playing a video
//  still connects to Google (PRIVACY.md lists the hosts).
//

#if !os(tvOS)
import Foundation
import MediaSourceKit
import YouTubePlayerKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum YouTubeEmbedClient {
    /// A player for `link`, starting at its time, playing as soon as it loads.
    static func player(for link: HostedVideoLink) -> YouTubePlayer {
        let start = link.startSeconds.map { Measurement(value: Double($0), unit: UnitDuration.seconds) }
        let parameters = YouTubePlayer.Parameters(autoPlay: true, startTime: start, showControls: true,
                                                  showFullscreenButton: true)
        let configuration = YouTubePlayer.Configuration(useNonPersistentWebsiteDataStore: true,
                                                        openURLAction: openURLAction)
        return YouTubePlayer(source: .video(id: link.videoID), parameters: parameters, configuration: configuration)
    }

    /// Where a link the player won't load itself goes. YouTubePlayerKit's default opens every such address in the
    /// browser, including ones the page loads on its own; only YouTube's own pages (the title, the logo, a channel:
    /// links the viewer clicked) open there, and everything else is dropped.
    static let openURLAction = YouTubePlayer.OpenURLAction { url, _ in
        guard opensInBrowser(url) else { return }
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        await UIApplication.shared.open(url)
        #endif
    }

    /// Whether `url` is a YouTube page worth opening in the browser: https on a YouTube host.
    nonisolated static func opensInBrowser(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host(percentEncoded: false)?.lowercased() else {
            return false
        }
        return ["youtube.com", "youtu.be"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// YouTubePlayerKit's MIT notice for Settings › About (the text of LICENSES/MIT-YouTubePlayerKit.txt).
    static let licenseText = """
        The MIT License (MIT)

        Copyright (c) 2025 Sven Tiigi

        Permission is hereby granted, free of charge, to any person obtaining a copy
        of this software and associated documentation files (the "Software"), to deal
        in the Software without restriction, including without limitation the rights
        to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
        copies of the Software, and to permit persons to whom the Software is
        furnished to do so, subject to the following conditions:

        The above copyright notice and this permission notice shall be included in all
        copies or substantial portions of the Software.

        THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
        IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
        FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
        AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
        LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
        OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
        SOFTWARE.
        """

    /// A sentence for the player's error state.
    static func message(for error: YouTubePlayer.Error) -> String {
        switch error {
        case .embeddedVideoPlayingNotAllowed:
            String(localized: "The video's owner doesn't allow it to play outside YouTube.")
        case .notFound, .invalidSource:
            String(localized: "This video isn't available. It may be private or removed.")
        case .iFrameApiFailedToLoad, .didFailNavigation, .didFailProvisionalNavigation:
            String(localized: "YouTube's player couldn't load. Check your internet connection.")
        default:
            String(localized: "YouTube's player stopped with an error.")
        }
    }
}
#endif
