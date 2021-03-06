//
//  SyntaxParser.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by 1024jp on 2018-04-28.
//
//  ---------------------------------------------------------------------------
//
//  © 2004-2007 nakamuxu
//  © 2014-2020 1024jp
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

import Foundation
import AppKit.NSTextStorage

protocol SyntaxParserDelegate: AnyObject {
    
    func syntaxParser(_ syntaxParser: SyntaxParser, didParseOutline outlineItems: [OutlineItem])
    func syntaxParser(_ syntaxParser: SyntaxParser, didStartParsingOutline progress: Progress)
}


extension NSAttributedString.Key {
    
    static let syntaxType = NSAttributedString.Key("CotEditor.SyntaxType")
}



final class SyntaxParser {
    
    static let didUpdateOutlineNotification = Notification.Name("SyntaxStyleDidUpdateOutline")
    
    private struct Cache {
        
        var styleName: String
        var string: String
        var highlights: [SyntaxType: [NSRange]]
    }
    
    
    // MARK: Public Properties
    
    let textStorage: NSTextStorage
    
    var style: SyntaxStyle
    
    weak var delegate: SyntaxParserDelegate?
    
    private(set) var outlineItems: [OutlineItem] = [] {
        
        didSet {
            // inform about outline items update
            DispatchQueue.main.async { [weak self, items = self.outlineItems] in
                guard let self = self else { return assertionFailure() }
                
                self.delegate?.syntaxParser(self, didParseOutline: items)
                NotificationCenter.default.post(name: SyntaxParser.didUpdateOutlineNotification, object: self)
            }
        }
    }
    
    
    // MARK: Private Properties
    
    private let outlineParseOperationQueue = OperationQueue(name: "com.coteditor.CotEditor.outlineParseOperationQueue")
    private let syntaxHighlightParseOperationQueue = OperationQueue(name: "com.coteditor.CotEditor.syntaxHighlightParseOperationQueue")
    
    private var highlightCache: Cache?  // results cache of the last whole string highlights
    
    private lazy var outlineUpdateTask = Debouncer(delay: .milliseconds(400)) { [weak self] in self?.parseOutline() }
    
    
    
    // MARK: -
    // MARK: Lifecycle
    
    init(textStorage: NSTextStorage, style: SyntaxStyle = SyntaxStyle()) {
        
        self.textStorage = textStorage
        self.style = style
    }
    
    
    deinit {
        self.invalidateCurrentParse()
    }
    
    
    
    // MARK: Public Methods
    
    /// whether enable parsing syntax
    var canParse: Bool {
        
        return UserDefaults.standard[.enableSyntaxHighlight] && !self.style.isNone
    }
    
    
    /// cancel all syntax parse
    func invalidateCurrentParse() {
        
        self.highlightCache = nil
        self.outlineUpdateTask.cancel()
        self.outlineParseOperationQueue.cancelAllOperations()
        self.syntaxHighlightParseOperationQueue.cancelAllOperations()
    }
    
}



// MARK: - Outline

extension SyntaxParser {
    
    /// parse outline with delay
    func invalidateOutline() {
        
        guard
            self.canParse,
            !self.style.outlineExtractors.isEmpty
            else {
                self.outlineItems = []
                return
        }
        
        self.outlineUpdateTask.schedule()
    }
    
    
    
    // MARK: Private Methods
    
    /// parse outline
    private func parseOutline() {
        
        let wholeRange = self.textStorage.range
        guard !wholeRange.isEmpty else {
            self.outlineItems = []
            return
        }
        
        let operation = OutlineParseOperation(extractors: self.style.outlineExtractors,
                                              string: self.textStorage.string.immutable,
                                              range: wholeRange)
        
        operation.completionBlock = { [weak self, weak operation] in
            guard let operation = operation, !operation.isCancelled else { return }
            
            self?.outlineItems = operation.results
        }
        operation.qualityOfService = .utility
        
        // -> Regarding the outline extraction, just cancel previous operations before pasing the latest string,
        //    since user cannot cancel it manually.
        self.outlineParseOperationQueue.cancelAllOperations()
        
        self.outlineParseOperationQueue.addOperation(operation)
        
        self.delegate?.syntaxParser(self, didStartParsingOutline: operation.progress)
    }
    
}



// MARK: - Syntax Highlight

extension SyntaxParser {
    
    /// update whole document highlights
    func highlightAll(completionHandler: @escaping (() -> Void) = {}) -> Progress? {
        
        assert(Thread.isMainThread)
        
        guard UserDefaults.standard[.enableSyntaxHighlight] else { return nil }
        guard !self.textStorage.string.isEmpty else { return nil }
        
        let wholeRange = self.textStorage.range
        
        // use cache if the content of the whole document is the same as the last
        if let cache = self.highlightCache, cache.styleName == self.style.name, cache.string == self.textStorage.string {
            self.apply(highlights: cache.highlights, range: wholeRange)
            completionHandler()
            return nil
        }
        
        // make sure that string is immutable
        //   -> `string` of NSTextStorage is actually a mutable object
        //      and it can cause crash when a mutable string is given to NSRegularExpression instance.
        //      (2016-11, macOS 10.12.1 SDK)
        let string = self.textStorage.string.immutable
        
        return self.highlight(string: string, range: wholeRange, completionHandler: completionHandler)
    }
    
    
    /// update highlights around passed-in range
    func highlight(around editedRange: NSRange) -> Progress? {
        
        assert(Thread.isMainThread)
        
        guard UserDefaults.standard[.enableSyntaxHighlight] else { return nil }
        guard !self.textStorage.string.isEmpty else { return nil }
        
        // make sure that string is immutable (see `highlightAll()` for details)
        let string = self.textStorage.string.immutable
        
        let wholeRange = self.textStorage.range
        let bufferLength = UserDefaults.standard[.coloringRangeBufferLength]
        
        // in case that wholeRange length is changed from editedRange
        guard editedRange.upperBound <= wholeRange.upperBound else { return nil }
        
        var highlightRange = editedRange
        
        // highlight whole if string is enough short
        if wholeRange.length <= bufferLength {
            highlightRange = wholeRange
            
        } else {
            // highlight whole visible area if edited point is visible
            for layoutManager in self.textStorage.layoutManagers {
                guard let visibleRange = layoutManager.firstTextView?.visibleRange else { continue }
                
                highlightRange.formUnion(visibleRange)
            }
            
            highlightRange = highlightRange.intersection(wholeRange) ?? wholeRange
            highlightRange = (string as NSString).lineRange(for: highlightRange)
            
            // expand highlight area if the character just before/after the highlighting area is the same color
            if let layoutManager = self.textStorage.layoutManagers.first {
                var start = highlightRange.lowerBound
                var end = highlightRange.upperBound
                
                if start <= bufferLength {
                    start = 0
                } else if let effectiveRange = layoutManager.effectiveRange(of: .foregroundColor, at: start) {
                    start = effectiveRange.lowerBound
                }
                
                if let effectiveRange = layoutManager.effectiveRange(of: .foregroundColor, at: end) {
                    end = effectiveRange.upperBound
                }
                
                highlightRange = NSRange(start..<end)
            }
        }
        
        return self.highlight(string: string, range: highlightRange)
    }
    
    
    
    // MARK: Private Methods
    
    /// perform highlighting
    private func highlight(string: String, range highlightRange: NSRange, completionHandler: @escaping (() -> Void) = {}) -> Progress? {
        
        assert(Thread.isMainThread)
        
        guard !highlightRange.isEmpty else { return nil }
        
        // just clear current highlight and return if no coloring needs
        guard self.style.hasHighlightDefinition else {
            self.apply(highlights: [:], range: highlightRange)
            completionHandler()
            return nil
        }
        
        let wholeRange = string.nsRange
        let styleName = self.style.name
        
        let definition = SyntaxHighlightParseOperation.ParseDefinition(extractors: self.style.highlightExtractors,
                                                                       pairedQuoteTypes: self.style.pairedQuoteTypes,
                                                                       inlineCommentDelimiter: self.style.inlineCommentDelimiter,
                                                                       blockCommentDelimiters: self.style.blockCommentDelimiters)
        
        let operation = SyntaxHighlightParseOperation(definition: definition, string: string, range: highlightRange)
        operation.qualityOfService = .userInitiated
        
        // give up if the editor's string is changed from the parsed string
        let isModified = Atomic(false)
        weak var modificationObserver: NSObjectProtocol?
        modificationObserver = NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: self.textStorage, queue: nil) { [weak operation] (note) in
            guard (note.object as! NSTextStorage).editedMask.contains(.editedCharacters) else { return }
            
            isModified.mutate { $0 = true }
            operation?.cancel()
            
            if let observer = modificationObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        
        operation.completionBlock = { [weak self, weak operation] in
            guard
                let operation = operation,
                let highlights = operation.highlights,
                !operation.isCancelled
                else {
                    if let observer = modificationObserver {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    return completionHandler()
                }
            
            DispatchQueue.main.async { [weak self, progress = operation.progress] in
                defer {
                    if let observer = modificationObserver {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    completionHandler()
                }
                
                guard !isModified.value else {
                    progress.cancel()
                    return
                }
                
                // cache result if whole text was parsed
                if highlightRange == wholeRange {
                    self?.highlightCache = Cache(styleName: styleName, string: string, highlights: highlights)
                }
                
                self?.apply(highlights: highlights, range: highlightRange)
                
                progress.completedUnitCount += 1
            }
        }
        
        self.syntaxHighlightParseOperationQueue.addOperation(operation)
        
        return operation.progress
    }
    
    
    /// apply highlights to the document
    private func apply(highlights: [SyntaxType: [NSRange]], range highlightRange: NSRange) {
        
        assert(Thread.isMainThread)
        
        guard self.textStorage.length > 0 else { return }
        
        let hasHighlight = highlights.values.contains { !$0.isEmpty }
        
        for layoutManager in self.textStorage.layoutManagers {
            // skip if never colorlized yet to avoid heavy `layoutManager.invalidateDisplay(forCharacterRange:)`
            guard hasHighlight || layoutManager.hasTemporaryAttribute(.syntaxType, in: highlightRange) else { continue }
            
            layoutManager.groupTemporaryAttributesUpdate(in: highlightRange) {
                layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: highlightRange)
                layoutManager.removeTemporaryAttribute(.syntaxType, forCharacterRange: highlightRange)
                
                guard let theme = (layoutManager.firstTextView as? Themable)?.theme else { return }
                
                for type in SyntaxType.allCases {
                    guard let ranges = highlights[type], !ranges.isEmpty else { continue }
                    
                    if let color = theme.style(for: type)?.color {
                        for range in ranges {
                            layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
                            layoutManager.addTemporaryAttribute(.syntaxType, value: type, forCharacterRange: range)
                        }
                    } else {
                        for range in ranges {
                            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
                            layoutManager.removeTemporaryAttribute(.syntaxType, forCharacterRange: range)
                        }
                    }
                }
            }
        }
    }
    
}



extension NSLayoutManager {
    
    /// Apply the theme based on the current `syntaxType` attributes.
    ///
    /// - Parameter theme: The theme to apply.
    /// - Parameter range: The range to invalidate. If `nil`, whole string will be invalidated.
    func invalidateHighlight(theme: Theme, range: NSRange? = nil) {
        
        assert(Thread.isMainThread)
        
        let wholeRange = range ?? self.attributedString().range
        
        self.groupTemporaryAttributesUpdate(in: wholeRange) {
            self.enumerateTemporaryAttribute(.syntaxType, in: wholeRange) { (type, range, _) in
                guard let type = type as? SyntaxType else { return }
                
                if let color = theme.style(for: type)?.color {
                    self.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range)
                } else {
                    self.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
                }
            }
        }
    }
    
}
