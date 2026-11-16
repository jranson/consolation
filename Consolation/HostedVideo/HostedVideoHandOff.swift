//
//  HostedVideoHandOff.swift
//  Consolation
//
//  Apple TV has no WebKit, so YouTube's embedded player can't run there: the video goes to the YouTube app through
//  its URL scheme instead. When the app isn't installed or won't take the link, the player says so.
//  `youtube://watch/<id>` is reported to work with the tvOS YouTube app [B]; YouTube doesn't document it.
//

#if os(tvOS)
import MediaSourceKit
import UIKit

enum HostedVideoHandOff {
    static let failureMessage = String(localized: """
        YouTube videos play on Apple TV in the YouTube app. Install it from the App Store, or play this link on a \
        Mac, iPad or iPhone.
        """)

    /// The YouTube app's link for a video.
    static func appURL(for link: HostedVideoLink) -> URL? {
        var components = URLComponents()
        components.scheme = "youtube"
        components.host = "watch"
        components.path = "/" + link.videoID
        if let start = link.startSeconds { components.queryItems = [URLQueryItem(name: "t", value: String(start))] }
        return components.url
    }

    /// Opens the video in the YouTube app; `completion` says whether an app took it.
    static func open(_ link: HostedVideoLink, completion: @escaping (Bool) -> Void) {
        guard let url = appURL(for: link) else { return completion(false) }
        UIApplication.shared.open(url, options: [:]) { opened in completion(opened) }
    }
}
#endif
