//
//  TextFinder.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by 1024jp on 2015-01-03.
//
//  ---------------------------------------------------------------------------
//
//  © 2015-2023 1024jp
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import AppKit
import Combine
import SwiftUI

@objc protocol TextFinderClient: AnyObject {
    
    func performEditorTextFinderAction(_ sender: Any?)
    func matchNext(_ sender: Any?)
    func matchPrevious(_ sender: Any?)
    func incrementalSearch(_ sender: Any?)
}


enum TextFindResult {
    
    case found(_ matches: [NSRange])
    case replaced(_ count: Int)
    
    
    /// The number of processed.
    var count: Int {
        
        switch self {
            case .found(let ranges):
                return ranges.count
            case .replaced(let count):
                return count
        }
    }
    
    
    /// Short result message for user.
    var message: String {
        
        switch self {
            case .found:
                switch self.count {
                    case ...0:
                        return String(localized: "Not found")
                    default:
                        return String(localized: "\(self.count) found")
                }
                
            case .replaced:
                switch self.count {
                    case ...0:
                        return String(localized: "Not replaced")
                    default:
                        return String(localized: "\(self.count) replaced")
                }
        }
    }
}



struct TextFindAllResult {
    
    struct Match {
        
        var range: NSRange
        var attributedLineString: NSAttributedString
    }
    
    
    var findString: String
    var matches: [Match]
}



// MARK: -

final class TextFinder {
    
    enum Action: Int {
        
        // NSTextFinder.Action
        case showFindInterface = 1
        case nextMatch = 2
        case previousMatch = 3
        case replaceAll = 4
        case replace = 5
        case replaceAndFind = 6
        case setSearchString = 7
        case replaceAllInSelection = 8  // not supported
        case selectAll = 9
        case selectAllInSelection = 10  // not supported
        case hideFindInterface = 11     // not supported
        case showReplaceInterface = 12  // not supported
        case hideReplaceInterface = 13  // not supported
        
        // TextFinder.Action
        case findAll = 101
        case setReplaceString = 102
        case highlight = 103
        case unhighlight = 104
        case showMultipleReplaceInterface = 105
    }
    
    
    // MARK: Public Properties
    
    static let didFindNotification = Notification.Name("didFindNotification")
    static let didFindAllNotification = Notification.Name("didFindAllNotification")
    
    weak var client: NSTextView!
    
    private(set) var findResult: TextFindResult?
    private(set) var findAllResult: TextFindAllResult?
    
    
    // MARK: Private Properties
    
    private var findTask: Task<Void, any Error>?
    private var highlightObserver: AnyCancellable?
    
    
    
    // MARK: -
    // MARK: Lifecycle
    
    deinit {
        self.findTask?.cancel()
    }
    
    
    
    // MARK: Public Methods
    
    /// Schedule incremental search.
    func incrementalSearch() {
        
        self.findTask?.cancel()
        self.findTask = Task.detached(priority: .userInitiated) {
            // debounce
            try await Task.sleep(nanoseconds: 200_000_000)  // 200 milliseconds
            
            try await self.find(forward: true, isIncremental: true)
        }
    }
    
    
    /// Allows validation of the find action before performing.
    ///
    /// - Parameter action: The sender’s tag.
    /// - Returns: `true` if the operation is valid; otherwise `false`.
    func validateAction(_ action: Action) -> Bool {
        
        switch action {
            case .showFindInterface,
                 .showMultipleReplaceInterface:
                return true
                
            case .nextMatch,
                 .previousMatch,
                 .setSearchString,
                 .selectAll,
                 .findAll,
                 .setReplaceString:
                return self.client.isSelectable
                
            case .replaceAll,
                 .replace,
                 .replaceAndFind:
                return self.client.isEditable
                
            case .highlight,
                 .unhighlight:
                return true
                
            case .selectAllInSelection,
                 .replaceAllInSelection,
                 .hideFindInterface,
                 .showReplaceInterface,
                 .hideReplaceInterface:
                // not supported in TextFinder
                return false
        }
    }
    
    
    /// Performs the specified text finding action.
    ///
    /// - Parameter action: The text finding action.
    @MainActor func performAction(_ action: Action) {
        
        guard self.validateAction(action) else { return }
        
        switch action {
            case .showFindInterface:
                FindPanelController.shared.showWindow(nil)
                
            case .nextMatch:
                self.nextMatch()
                
            case .previousMatch:
                self.previousMatch()
                
            case .replaceAll:
                self.replaceAll()
                
            case .replace:
                self.replace()
                
            case .replaceAndFind:
                self.replaceAndFind()
                
            case .setSearchString:
                self.setSearchString()
                
            case .selectAll:
                self.selectAll()
                
            case .replaceAllInSelection,
                 .selectAllInSelection,
                 .hideFindInterface,
                 .showReplaceInterface,
                 .hideReplaceInterface:
                // not supported in TextFinder
                assertionFailure()
                
            case .findAll:
                self.findAll()
                
            case .setReplaceString:
                self.setReplaceString()
                
            case .highlight:
                self.highlight()
                
            case .unhighlight:
                self.unhighlight()
                
            case .showMultipleReplaceInterface:
                MultipleReplacePanelController.shared.showWindow(nil)
        }
    }
    
    
    
    // MARK: Private Actions
    
    /// Find next matched string.
    @MainActor private func nextMatch() {
        
        self.findTask?.cancel()
        self.findTask = Task(priority: .userInitiated) {
            try await self.find(forward: true)
        }
    }
    
    
    /// Find previous matched string.
    @MainActor private func previousMatch() {
        
        self.findTask?.cancel()
        self.findTask = Task(priority: .userInitiated) {
            try await self.find(forward: false)
        }
    }
    
    
    /// Select all matched strings.
    @MainActor private func selectAll() {
        
        guard let textFind = self.prepareTextFind() else { return }
        guard let matchedRanges = try? textFind.matches else { return }
        
        self.client.selectedRanges = matchedRanges as [NSValue]
        
        self.notify(result: .found(matchedRanges))
        TextFinderSettings.shared.noteFindHistory()
    }
    
    
    /// Find all matched strings and show results in a table.
    @MainActor private func findAll() {
        
        Task {
            await self.findAll(showsList: true, actionName: "Find All")
        }
    }
    
    
    /// Highlight all matched strings.
    @MainActor private func highlight() {
        
        Task {
            await self.findAll(showsList: false, actionName: "Highlight All")
        }
    }
    
    
    /// Remove all of current highlights in the frontmost textView.
    @MainActor private func unhighlight() {
        
        self.client.unhighlight(nil)
    }
    
    
    /// Replace matched string in selection with replacementString.
    @MainActor private func replace() {
        
        if self.replaceSelected() {
            self.client.centerSelectionInVisibleArea(self)
        } else {
            NSSound.beep()
        }
        
        TextFinderSettings.shared.noteReplaceHistory()
    }
    
    
    /// Replace matched string with replacementString and select the next match.
    @MainActor private func replaceAndFind() {
        
        self.replaceSelected()
        
        self.findTask?.cancel()
        self.findTask = Task(priority: .userInitiated) {
            try await self.find(forward: true)
        }
        
        TextFinderSettings.shared.noteReplaceHistory()
    }
    
    
    /// Replace all matched strings with given string.
    @MainActor private func replaceAll() {
        
        Task {
            await self.replaceAll()
        }
    }
    
    
    /// Set selected string to find field.
    @MainActor private func setSearchString() {
        
        TextFinderSettings.shared.findString = self.client.selectedString
        TextFinderSettings.shared.usesRegularExpression = false  // auto-disable regex
    }
    
    
    /// Set selected string to replace field.
    @MainActor private func setReplaceString() {
        
        TextFinderSettings.shared.replacementString = self.client.selectedString
    }
    
    
    
    // MARK: Private Methods
    
    /// Check Find can be performed and alert if needed.
    ///
    /// - Parameter presentsError: Whether shows error dialog on the find panel.
    /// - Returns: A TextFind object with the current state, or `nil` if not ready.
    @MainActor private func prepareTextFind(presentsError: Bool = true) -> TextFind? {
        
        let client = self.client!
        
        // close previous error dialog if any exists
        FindPanelController.shared.window?.attachedSheet?.close()
        
        // apply the client's line ending to the find string
        let lineEnding = (client as? EditorTextView)?.lineEnding ?? .lf
        let findString = TextFinderSettings.shared.findString
            .replacingLineEndings(with: lineEnding)
        
        let string = client.string.immutable
        let mode = TextFinderSettings.shared.mode
        let inSelection = TextFinderSettings.shared.inSelection
        let selectedRanges = client.selectedRanges.map(\.rangeValue)
        
        do {
            return try TextFind(for: string, findString: findString, mode: mode, inSelection: inSelection, selectedRanges: selectedRanges)
            
        } catch let error as TextFind.Error {
            guard presentsError else { return nil }
            
            switch error {
                case .regularExpression, .emptyInSelectionSearch:
                    FindPanelController.shared.showWindow(self)
                    FindPanelController.shared.presentError(error, modalFor: FindPanelController.shared.window!, delegate: nil, didPresent: nil, contextInfo: nil)
                case .emptyFindString:
                    break
            }
            NSSound.beep()
            
            return nil
            
        } catch {
            assertionFailure(error.localizedDescription)
            return nil
        }
    }
    
    
    /// Perform single find.
    ///
    /// - Parameters:
    ///   - forward: The flag whether finds forward or backward.
    ///   - isIncremental: Whether is the incremental search.
    /// - Throws: `CancellationError`
    @MainActor private func find(forward: Bool, isIncremental: Bool = false) async throws {
        
        assert(forward || !isIncremental)
        
        guard let textFind = self.prepareTextFind(presentsError: !isIncremental) else { return }
        
        let client = self.client!
        
        // find in background thread
        let (matches, result) = try await Task.detached(priority: .userInitiated) {
            let matches = try textFind.matches
            let result = textFind.find(in: matches, forward: forward, includingSelection: isIncremental, wraps: TextFinderSettings.shared.isWrap)
            return (matches, result)
        }.value
        
        // mark all matches
        if isIncremental, let layoutManager = client.layoutManager {
            layoutManager.groupTemporaryAttributesUpdate(in: client.string.nsRange) {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: client.string.nsRange)
                for range in matches {
                    layoutManager.addTemporaryAttribute(.backgroundColor, value: NSColor.unemphasizedSelectedTextBackgroundColor, forCharacterRange: range)
                }
            }
            
            // unmark either when the client view resigned the key window or when the Find panel closed
            self.highlightObserver = NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)
                .first()
                .sink { [weak client] _ in client?.unhighlight(nil) }
        }
        
        // found feedback
        if let result {
            client.select(range: result.range)
            client.showFindIndicator(for: result.range)
            
            if result.wrapped {
                client.enclosingScrollView?.superview?.showHUD(symbol: .wrap(flipped: !forward))
                client.requestAccessibilityAnnouncement("Search wrapped.".localized)
            }
        } else if !isIncremental {
            client.enclosingScrollView?.superview?.showHUD(symbol: forward ? .reachBottom : .reachTop)
            NSSound.beep()
        }
        
        self.notify(result: .found(matches))
        if !isIncremental {
            TextFinderSettings.shared.noteFindHistory()
        }
    }
    
    
    /// Replace matched string in selection with replacementString.
    @discardableResult
    @MainActor private func replaceSelected() -> Bool {
        
        guard let textFind = self.prepareTextFind() else { return false }
        
        let replacementString = TextFinderSettings.shared.replacementString
        
        guard let result = textFind.replace(with: replacementString) else { return false }
        
        // apply replacement to text view
        return self.client.replace(with: result.value, range: result.range,
                                   selectedRange: NSRange(location: result.range.location,
                                                          length: result.value.length),
                                   actionName: "Replace".localized)
    }
    
    
    /// Find all matched strings and apply the result to views.
    ///
    /// - Parameters:
    ///   - showsList: Whether shows the result view when finished.
    ///   - actionName: The name of the action to display in the progress sheet.
    @MainActor private func findAll(showsList: Bool, actionName: LocalizedStringKey) async {
        
        guard let textFind = self.prepareTextFind() else { return }
        
        let client = self.client!
        client.isEditable = false
        
        let highlightColors = NSColor.textHighlighterColor.usingColorSpace(.genericRGB)!.decomposite(into: textFind.numberOfCaptureGroups + 1)
        let lineCounter = LineCounter(textFind.string as NSString)
        
        // setup progress sheet
        let progress = FindProgress(scope: textFind.scopeRange)
        let indicatorView = FindProgressView(actionName, progress: progress, unit: .find)
        let indicator = NSHostingController(rootView: indicatorView)
        indicator.rootView.parent = indicator
        client.viewControllerForSheet?.presentAsSheet(indicator)
        
        let (highlights, matches) = await Task.detached(priority: .userInitiated) {
            var highlights: [ValueRange<NSColor>] = []
            var resultMatches: [TextFindAllResult.Match] = []  // not used if showsList is false
            
            textFind.findAll { (matches: [NSRange], stop) in
                guard !progress.isCancelled else {
                    stop = true
                    return
                }
                
                // highlight
                highlights += matches.enumerated()
                    .filter { !$0.element.isEmpty }
                    .map { ValueRange(value: highlightColors[$0.offset], range: $0.element) }
                
                // build TextFindResult for table
                if showsList {
                    let matchedRange = matches[0]
                    
                    // build a highlighted line string for result table
                    let lineRange = lineCounter.lineRange(for: matchedRange)
                    let lineString = (textFind.string as NSString).substring(with: lineRange)
                    let attrLineString = NSMutableAttributedString(string: lineString)
                    for (index, range) in matches.enumerated() where !range.isEmpty {
                        attrLineString.addAttribute(.backgroundColor,
                                                    value: highlightColors[index],
                                                    range: range.shifted(by: -lineRange.location))
                    }
                    attrLineString.truncateHead(until: matchedRange.location - lineRange.location, offset: 16)
                    
                    resultMatches.append(.init(range: matchedRange, attributedLineString: attrLineString))
                }
                
                progress.completedUnit = matches[0].upperBound
                progress.count += 1
            }
            
            return (highlights, resultMatches)
        }.value
        
        client.isEditable = true
        
        guard !progress.isCancelled else { return }
        
        // highlight in client
        if let layoutManager = client.layoutManager {
            let wholeRange = textFind.string.nsRange
            layoutManager.groupTemporaryAttributesUpdate(in: wholeRange) {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: wholeRange)
                for highlight in highlights {
                    layoutManager.addTemporaryAttribute(.backgroundColor, value: highlight.value, forCharacterRange: highlight.range)
                }
            }
        }
        
        if highlights.isEmpty {
            NSSound.beep()
        }
        
        progress.isFinished = true
        
        self.notify(result: .found(matches.map(\.range)))
        
        if showsList {
            self.findAllResult = TextFindAllResult(findString: textFind.findString, matches: matches)
            NotificationCenter.default.post(name: TextFinder.didFindAllNotification, object: self)
        }
        
        TextFinderSettings.shared.noteFindHistory()
    }
    
    
    /// Replace all matched strings and apply the result to views.
    @MainActor private func replaceAll() async {
        
        guard let textFind = self.prepareTextFind() else { return }
        
        let client = self.client!
        client.isEditable = false
        
        let replacementString = TextFinderSettings.shared.replacementString
        
        // setup progress sheet
        let progress = FindProgress(scope: textFind.scopeRange)
        let indicatorView = FindProgressView("Replace All", progress: progress, unit: .replacement)
        let indicator = NSHostingController(rootView: indicatorView)
        indicator.rootView.parent = indicator
        client.viewControllerForSheet?.presentAsSheet(indicator)
        
        let (replacementItems, selectedRanges) = await Task.detached(priority: .userInitiated) {
            textFind.replaceAll(with: replacementString) { (range, count, stop) in
                guard !progress.isCancelled else {
                    stop = true
                    return
                }
                
                progress.completedUnit = range.upperBound
                progress.count += count
            }
        }.value
        
        client.isEditable = true
        
        guard !progress.isCancelled else { return }
        
        if !replacementItems.isEmpty {
            // apply found strings to the text view
            client.replace(with: replacementItems.map(\.value), ranges: replacementItems.map(\.range), selectedRanges: selectedRanges,
                           actionName: "Replace All".localized)
        }
        
        if progress.count > 0 {
            NSSound.beep()
        }
        
        progress.isFinished = true
        
        self.notify(result: .replaced(progress.count))
        TextFinderSettings.shared.noteReplaceHistory()
    }
    
    
    /// Notify find/replacement result to the user.
    ///
    /// - Parameters:
    ///   - result: The result of the process.
    private func notify(result: TextFindResult) {
        
        self.findResult = result
        NotificationCenter.default.post(name: TextFinder.didFindNotification, object: self)
        
        self.client?.requestAccessibilityAnnouncement(result.message)
    }
}



// MARK: -

extension NSTextView {
    
    @IBAction func unhighlight(_ sender: Any?) {
        
        self.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: self.string.nsRange)
    }
}



// MARK: -

private final class LineCounter: LineRangeCacheable {
    
    let string: NSString
    var lineRangeCache = LineRangeCache()
    
    
    init(_ string: NSString) {
        
        self.string = string
    }
}
