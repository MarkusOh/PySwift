//
//  ViewController.swift
//  YouTube Parser
//
//  Created by Seungsub Oh on 2023/03/28.
//

import UIKit

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view.
        
//        let youtube = YouTube(url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        let youtube = YouTube(url: "https://youtube.com/live/LjJOEIQyXH8")
        
        Task {
            let html = try? await youtube.watchHtml()
            
            do {
                try await youtube.checkAvailability()
            } catch {
                print(error)
            }
        }
    }


}

struct YouTube {
    let videoId: String
    let watchUrl: URL
    let embedUrl: URL
    var cachedWatchHtml: String?
    var cachedEmbedHtml: String?
    
    init(url: String) {
        videoId = YouTube.getVideoId(from: url)!
        watchUrl = URL(string: "https://youtube.com/watch?v=\(videoId)")!
        embedUrl = URL(string: "https://www.youtube.com/embed/\(videoId)")!
    }
    
    func watchHtml() async throws -> String {
        if let cachedWatchHtml = cachedWatchHtml {
            return cachedWatchHtml
        } else {
            return try await YouTube.get(url: watchUrl)
        }
    }
    
    func embedHtml() async throws -> String {
        if let cachedEmbedHtml = cachedEmbedHtml {
            return cachedEmbedHtml
        } else {
            return try await YouTube.get(url: embedUrl)
        }
    }
    
    enum RegexMatchError: Error {
        case notFound(String, String)
    }
    
    static func getVideoId(from url: String) -> String? {
        let pattern = "(?:v=|\\/)([0-9A-Za-z_-]{11}).*"
        guard let result = try? regexSearch(pattern: pattern, string: url, group: 1) else {
            return nil
        }
        
        return result
    }
    
    static func regexSearch(pattern: String, string: String, group: Int) throws -> String {
        // Shortcut method to search a string for a given pattern.
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: string.utf16.count)
        guard let match = regex.firstMatch(in: string, options: [], range: range) else {
            throw RegexMatchError.notFound("regexSearch", pattern)
        }
        
        let matchRange = match.range(at: group)
        if matchRange.location == NSNotFound {
            throw RegexMatchError.notFound("regexSearch", pattern)
        }
        
        return String(string[Range(matchRange, in: string)!])
    }
    
    enum AvailabilityError: Error {
        case noHtmlResponse, membersOnly, recordingUnavailable, videoUnavailable, privateVideo, unavailableVideo, liveStreamOnly
    }
    
    func checkAvailability() async throws {
        let watchHtml = try await watchHtml()
        let (status, messages) = try YouTube.playabilityStatus(watchHtml: watchHtml)
        
        for reason in messages {
            if status == "UNPLAYABLE" {
                let knownReasons = [
                    "Join this channel to get access to members-only content ",
                    "like this video, and other exclusive perks."
                ]
                
                if let reason = reason, knownReasons.contains(reason) {
                    throw AvailabilityError.membersOnly
                } else if reason == "This live stream recording is not available." {
                    throw AvailabilityError.recordingUnavailable
                } else {
                    throw AvailabilityError.videoUnavailable
                }
            } else if status == "LOGIN_REQUIRED" {
                throw AvailabilityError.privateVideo
            } else if status == "ERROR" {
                throw AvailabilityError.videoUnavailable
            } else if status == "LIVE_STREAM" {
                throw AvailabilityError.liveStreamOnly
            }
        }
    }
    
    enum HTMLParseError: Error {
        case invalidObject, noMatches(String), parseFailure, invalidStartPoint(Int), noLastElementInStack
    }
    
    static func playabilityStatus(watchHtml: String) throws -> (String?, [String?]) {
        let playerResponse = try initialPlayerResponse(watchHtml: watchHtml)
        
        let statusDict = playerResponse["playabilityStatus"] as? [String: Any] ?? [:]
        
        if let liveStreamability = statusDict["liveStreamability"] as? String {
            return ("LIVE_STREAM", [liveStreamability])
        }
        
        if let status = statusDict["status"] as? String {
            if let reason = statusDict["reason"] as? String {
                return (status, [reason])
            }
            
            if let messages = statusDict["messages"] as? [String] {
                return (status, messages.map { $0 as Optional })
            }
        }
        
        return (nil, [nil])
    }
    
    static func initialPlayerResponse(watchHtml: String) throws -> [String: Any] {
        let patterns = [
            "window\\[['\"]ytInitialPlayerResponse['\"]]\\s*=\\s*",
            "ytInitialPlayerResponse\\s*=\\s*"
        ]
        
        var errorsCollection: [Error] = []
        for pattern in patterns {
            do {
                return try parseForObject(html: watchHtml, precedingRegex: pattern)
            } catch {
                errorsCollection.append(error)
            }
        }
        
        // If none of the patterns match, raise a RegexMatchError
        throw errorsCollection.last!
    }
    
    static func parseForAllObjects(html: String, precedingRegex: String) throws -> [[String: Any]] {
        var result = [[String: Any]]()
        let regex = try NSRegularExpression(pattern: precedingRegex)
        let matchIter = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        for match in matchIter {
            let startIndex = match.range(at: 0).upperBound
            do {
                let obj = try parseForObjectFromStartPoint(html: html, startPoint: startIndex)
                result.append(obj)
            } catch HTMLParseError.invalidObject {
                // Some of the instances might fail because set is technically
                // a method of the ytcfg object. We'll skip these since they
                // don't seem relevant at the moment.
                continue
            }
        }
        if result.count == 0 {
            throw HTMLParseError.noMatches(precedingRegex)
        }
        return result
    }
    
    static func parseForObject(html: String, precedingRegex: String) throws -> [String: Any] {
        let regex = try NSRegularExpression(pattern: precedingRegex)
        let result = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html))
        guard let match = result else {
            throw HTMLParseError.noMatches(precedingRegex)
        }
        let startIndex = match.range.upperBound
        return try parseForObjectFromStartPoint(html: html, startPoint: startIndex)
    }
    
    static func parseForObjectFromStartPoint(html: String, startPoint: Int) throws -> [String: Any] {
        let fullObj = try findObjectFromStartpoint(html: html, startPoint: startPoint)
        do {
            return try JSONSerialization.jsonObject(with: fullObj.data(using: .utf8)!, options: []) as! [String: Any]
        } catch {
            do {
                return try JSONSerialization.jsonObject(with: fullObj.data(using: .utf8)!, options: []) as! [String: Any]
            } catch {
                throw HTMLParseError.parseFailure
            }
        }
    }
    
    static func findObjectFromStartpoint(html: String, startPoint: Int) throws -> String {
        let startPointIndex = html.index(html.startIndex, offsetBy: startPoint)
        var html = html[startPointIndex..<html.endIndex]
        if !["{", "["].contains(html[html.startIndex]) {
            throw HTMLParseError.invalidStartPoint(startPoint)
        }

        var lastChar: Character = "{"
        var currChar: Character? = nil
        var stack = [html[html.startIndex]]
        var i = html.index(html.startIndex, offsetBy: 1)

        let contextClosers: [Character: Character] = [
            "{": "}",
            "[": "]",
            "\"": "\"",
            "/": "/" // javascript regex
        ]

        while i < html.endIndex {
            if stack.isEmpty {
                break
            }
            if let currChar = currChar, ![" ", "\n"].contains(currChar) {
                lastChar = currChar
            }
            currChar = html[i]

            guard let currContext = stack.last else {
                throw HTMLParseError.noLastElementInStack
            }

            // If we've reached a context closer, we can remove an element off the stack
            if currChar == contextClosers[currContext] {
                stack.removeLast()
                i = html.index(after: i)
                continue
            }

            // Strings and regex expressions require special context handling because they can contain
            //  context openers *and* closers
            if ["\"", "/"].contains(currContext) {
                // If there's a backslash in a string or regex expression, we skip a character
                if currChar == "\\" {
                    i = html.index(i, offsetBy: 2)
                    continue
                }
            } else {
                // Non-string contexts are when we need to look for context openers.
                if let _ = contextClosers[currChar!] {
                    // Slash starts a regular expression depending on context
                    if !(currChar == "/" && !["(", ",", "=", ":", "[", "!", "&", "|", "?", "{", "}", ";"].contains(lastChar)) {
                        stack.append(currChar!)
                    }
                }
            }

            i = html.index(after: i)
        }

        let fullObj = html[html.startIndex..<i]
        return String(fullObj)
    }


    enum RequestError: Error {
        case invalidRequestData, decodeToUTF8Error
    }

    static func executeRequest(
        url: URL,
        method: String? = nil,
        headers: [String: String]? = nil,
        data: Any? = nil
    ) async throws -> Data {
        let baseHeaders = ["User-Agent": "Mozilla/5.0", "accept-language": "en-US,en"]
        var request = URLRequest(url: url)
        request.httpMethod = method ?? "GET"
        
        for (key, value) in baseHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        
        if let headers = headers {
            for (key, value) in headers {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }
        
        if let data = data {
            if let jsonData = try? JSONSerialization.data(withJSONObject: data, options: []) {
                request.httpBody = jsonData
            } else if let stringData = data as? String {
                request.httpBody = stringData.data(using: .utf8)
            } else {
                throw RequestError.invalidRequestData
            }
        }
        
        var responseData: Data?
        var responseError: Error?
        
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    static func get(url: URL, extraHeaders: [String: String]? = nil) async throws -> String {
        var headers = extraHeaders ?? [:]
        headers["User-Agent"] = "Mozilla/5.0"
        let data = try await executeRequest(url: url, headers: headers)
        if let str = String(data: data, encoding: .utf8) {
            return str
        } else {
            throw RequestError.decodeToUTF8Error
        }
    }
    
}







