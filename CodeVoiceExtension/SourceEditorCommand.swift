import Foundation
import AVFoundation
import XcodeKit
import FoundationModels

class SourceEditorCommand: NSObject, XCSourceEditorCommand, AVSpeechSynthesizerDelegate {

    private let synthesizer = AVSpeechSynthesizer()
    private var commandCompletion: ((Error?) -> Void)?

    func perform(with invocation: XCSourceEditorCommandInvocation, completionHandler: @escaping (Error?) -> Void) {
        self.commandCompletion = completionHandler
        self.synthesizer.delegate = self

        // Route based on the identifier defined in Info.plist
        let identifier = invocation.commandIdentifier
        
        if identifier.hasSuffix("ExplainSelection") {
            executeExplainSelectionFeature(invocation: invocation)
        } else if identifier.hasSuffix("CheckErrors") {
            executeCheckErrorsFeature(invocation: invocation)
        } else if identifier.hasSuffix("ReadStructure") {
            executeReadStructureFeature(invocation: invocation)
        } else if identifier.hasSuffix("ReadLine") {
            executeReadLineFeature(invocation: invocation)
        } else if identifier.hasSuffix("Summarize") {
            executeSummarizeFeature(invocation: invocation)
        } else {
            completionHandler(nil)
        }
    }

    // MARK: - Feature 1: Read Line Context (Simple Context with Exact Names)
    
    private func executeReadLineFeature(invocation: XCSourceEditorCommandInvocation) {
        let buffer = invocation.buffer
        guard let selection = buffer.selections.firstObject as? XCSourceTextRange else {
            commandCompletion?(nil)
            return
        }

        let lineIndex = selection.start.line
        guard lineIndex >= 0, lineIndex < buffer.lines.count,
              let sourceLine = buffer.lines[lineIndex] as? String else {
            commandCompletion?(nil)
            return
        }

        let code = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let context = findParentContext(in: buffer.lines, startingFrom: lineIndex)
        let contextPhrase = context != nil ? "Inside \(context!)." : "At global scope."

        let message = code.isEmpty
            ? "\(contextPhrase) Line \(lineIndex + 1). Empty line."
            : "\(contextPhrase) Line \(lineIndex + 1). Code: \(code)"

        speak(message: message)
    }
    
    private func findParentContext(in lines: NSMutableArray, startingFrom lineIndex: Int) -> String? {
        var openBracesNeeded = 1
        for i in stride(from: lineIndex - 1, through: 0, by: -1) {
            guard let line = lines[i] as? String else { continue }
            let cleaned = cleanCodeLine(line)
            
            openBracesNeeded += cleaned.filter { $0 == "}" }.count
            openBracesNeeded -= cleaned.filter { $0 == "{" }.count
            
            if openBracesNeeded <= 0 {
                let headerText = findHeaderLineText(in: lines, upTo: i)
                return identifyContext(from: headerText)
            }
        }
        return nil
    }

    // MARK: - Feature 2: Read Code Structure (Detailed Accessibility Context)

    private func executeReadStructureFeature(invocation: XCSourceEditorCommandInvocation) {
        let buffer = invocation.buffer
        guard let selection = buffer.selections.firstObject as? XCSourceTextRange else {
            commandCompletion?(nil)
            return
        }

        let lineIndex = selection.start.line
        guard lineIndex >= 0, lineIndex < buffer.lines.count,
              let sourceLine = buffer.lines[lineIndex] as? String else {
            commandCompletion?(nil)
            return
        }

        let currentLineNum = lineIndex + 1
        let code = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
        
        let allBlocks = parseAllBlocks(in: buffer.lines)
        let enclosingBlocks = allBlocks
            .filter { $0.startLine <= currentLineNum && $0.endLine >= currentLineNum }
            .sorted { ($0.endLine - $0.startLine) < ($1.endLine - $1.startLine) }

        // 1. Indentation level
        let nestingLevel = enclosingBlocks.count
        let indentPhrase = "Indentation level: \(nestingLevel)."

        // 2. Parent context
        let contextPhrase: String
        if enclosingBlocks.isEmpty {
            contextPhrase = "Parent context: Global scope."
        } else {
            let contexts = enclosingBlocks.map { $0.contextDescription }.joined(separator: " inside ")
            contextPhrase = "Parent context: \(contexts)."
        }

        // 3. Code range
        let rangePhrase: String
        if enclosingBlocks.isEmpty {
            rangePhrase = "Code range: Global scope."
        } else {
            let currentBlock = enclosingBlocks[0]
            var rangeDetails = "Current block range: lines \(currentBlock.startLine) to \(currentBlock.endLine)."
            if enclosingBlocks.count > 1 {
                let parentRanges = enclosingBlocks[1...].map { "lines \($0.startLine) to \($0.endLine)" }.joined(separator: "; ")
                rangeDetails += " Parent block ranges: \(parentRanges)."
            }
            rangePhrase = rangeDetails
        }

        let lineCodePhrase = code.isEmpty
            ? "Line \(currentLineNum): Empty line."
            : "Line \(currentLineNum): \(code)."

        let message = "\(lineCodePhrase) \(indentPhrase) \(contextPhrase) \(rangePhrase)"
        speak(message: message)
    }

    // MARK: - Feature 3: Check Code Errors & Warnings (Simplified Line Reading)

    private func executeCheckErrorsFeature(invocation: XCSourceEditorCommandInvocation) {
        let buffer = invocation.buffer
        let fullText = buffer.completeBuffer
        
        // 1. Fast local check for unclosed or mismatched syntax
        var localIssues: [String] = []
        var symbolStack: [(char: Character, line: Int)] = []

        for i in 0..<buffer.lines.count {
            guard let lineStr = buffer.lines[i] as? String else { continue }
            let lineNum = i + 1
            let cleaned = cleanCodeLine(lineStr)
            
            var inString = false
            var prevChar: Character? = nil
            
            for char in cleaned {
                if char == "\"" && prevChar != "\\" {
                    inString.toggle()
                }
                
                if !inString {
                    if char == "{" || char == "(" || char == "[" {
                        symbolStack.append((char, lineNum))
                    } else if char == "}" || char == ")" || char == "]" {
                        if let last = symbolStack.last {
                            let matches = (last.char == "{" && char == "}") ||
                                          (last.char == "(" && char == ")") ||
                                          (last.char == "[" && char == "]")
                            if matches {
                                _ = symbolStack.popLast()
                            } else {
                                localIssues.append("Line \(lineNum): Unexpected closing '\(char)'. Expected closing bracket for '\(last.char)' opened at line \(last.line).")
                            }
                        } else {
                            localIssues.append("Line \(lineNum): Extra closing '\(char)' without an opening bracket.")
                        }
                    }
                }
                prevChar = char
            }
            
            if inString {
                localIssues.append("Line \(lineNum): Unclosed text quote.")
            }
        }

        while let unclosed = symbolStack.popLast() {
            localIssues.append("Line \(unclosed.line): Missing closing bracket for '\(unclosed.char)'.")
        }

        // Speak fast local issues if found
        if !localIssues.isEmpty {
            let issueCount = localIssues.count
            let summary = "Found \(issueCount) syntax issue\(issueCount > 1 ? "s" : ""): " + localIssues.joined(separator: " ")
            speak(message: summary)
            return
        }

        // 2. Deep check with LanguageModelSession for warnings, bugs, and simplified explanations
        Task {
            do {
                let session = LanguageModelSession(
                    instructions: """
                    You are an accessibility assistant for screen readers. Analyze the provided Swift code for errors, warnings, unused variables, or bad syntax.
                    If issues exist:
                    - Format each issue as 'Line [X]: [simplified, plain-English explanation]'.
                    - Explain what is wrong and how to fix it in simple terms without compiler jargon.
                    - List all issues found in chronological line order.
                    If no errors or warnings exist, reply strictly with 'No errors or warnings found.'
                    """
                )
                
                let aiResponse = try await session.respond(to: fullText)
                let aiResult = aiResponse.content.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = aiResult.isEmpty ? "No errors or warnings found." : aiResult
                
                await MainActor.run {
                    self.speak(message: message)
                }
            } catch {
                await MainActor.run {
                    self.speak(message: "No syntax errors found in standard check. AI code analysis unavailable.")
                }
            }
        }
    }

    // MARK: - Feature 4: Summarize File

    private func executeSummarizeFeature(invocation: XCSourceEditorCommandInvocation) {
        let fullText = invocation.buffer.completeBuffer
        
        let structCount = count(pattern: "\\bstruct\\s+", in: fullText)
        let classCount = count(pattern: "\\bclass\\s+", in: fullText)
        let funcCount = count(pattern: "\\bfunc\\s+", in: fullText)
        
        let structureMessage = "This file contains \(structCount) structs, \(classCount) classes, and \(funcCount) functions."
        
        Task {
            do {
                let session = LanguageModelSession(
                    instructions: "Analyze the following Swift code and provide a one-sentence summary of its primary purpose. Do not include any code, formatting, or introductory text."
                )
                
                let aiResponse = try await session.respond(to: fullText)
                let aiSummary = aiResponse.content
                let aiSummaryTrimmed = aiSummary.trimmingCharacters(in: .whitespacesAndNewlines)

                let finalMessage = aiSummaryTrimmed.isEmpty ? structureMessage : "\(structureMessage) Summary: \(aiSummaryTrimmed)"
                
                await MainActor.run {
                    self.speak(message: finalMessage)
                }
            } catch {
                await MainActor.run {
                    self.speak(message: "\(structureMessage) The AI summary could not be generated.")
                }
            }
        }
    }

    // MARK: - Feature 5: Explain Selected Code

    private func executeExplainSelectionFeature(invocation: XCSourceEditorCommandInvocation) {
        let buffer = invocation.buffer
        guard let selection = buffer.selections.firstObject as? XCSourceTextRange else {
            commandCompletion?(nil)
            return
        }

        let startLine = selection.start.line
        let endLine = selection.end.line
        
        var selectedLines: [String] = []
        for lineIndex in startLine...endLine {
            if lineIndex >= 0 && lineIndex < buffer.lines.count,
               let lineStr = buffer.lines[lineIndex] as? String {
                selectedLines.append(lineStr)
            }
        }
        
        let selectedCode = selectedLines.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard !selectedCode.isEmpty else {
            speak(message: "Please highlight a selection of code to explain.")
            return
        }

        Task {
            do {
                let session = LanguageModelSession(
                    instructions: """
                    You are an accessibility assistant for visually impaired developers.
                    Translate the provided Swift code snippet into a simple, single-sentence plain-English explanation.
                    Focus on what the code accomplishes conceptually. Do not repeat code syntax or output formatting.
                    """
                )
                
                let aiResponse = try await session.respond(to: selectedCode)
                let aiSummary = aiResponse.content.trimmingCharacters(in: .whitespacesAndNewlines)

                let finalMessage = aiSummary.isEmpty
                    ? "Could not explain selection."
                    : "Selection explanation: \(aiSummary)"
                
                await MainActor.run {
                    self.speak(message: finalMessage)
                }
            } catch {
                await MainActor.run {
                    self.speak(message: "Unable to explain selected code.")
                }
            }
        }
    }

    // MARK: - Structural Code Analysis Helpers

    private struct CodeBlock {
        let startLine: Int
        var endLine: Int
        let contextDescription: String
        let headerLineText: String
    }

    private struct PendingBlock {
        let startLine: Int
        let headerLineText: String
        let contextDescription: String
    }

    private func parseAllBlocks(in lines: NSMutableArray) -> [CodeBlock] {
        var completedBlocks: [CodeBlock] = []
        var stack: [PendingBlock] = []

        for i in 0..<lines.count {
            guard let lineStr = lines[i] as? String else { continue }
            let currentLineNum = i + 1
            let cleaned = cleanCodeLine(lineStr)

            for char in cleaned {
                if char == "{" {
                    let headerText = findHeaderLineText(in: lines, upTo: i)
                    let context = identifyContext(from: headerText)
                    stack.append(PendingBlock(startLine: currentLineNum, headerLineText: headerText, contextDescription: context))
                } else if char == "}" {
                    if let top = stack.popLast() {
                        let block = CodeBlock(
                            startLine: top.startLine,
                            endLine: currentLineNum,
                            contextDescription: top.contextDescription,
                            headerLineText: top.headerLineText
                        )
                        completedBlocks.append(block)
                    }
                }
            }
        }

        let totalLines = max(1, lines.count)
        while let top = stack.popLast() {
            completedBlocks.append(CodeBlock(
                startLine: top.startLine,
                endLine: totalLines,
                contextDescription: top.contextDescription,
                headerLineText: top.headerLineText
            ))
        }

        return completedBlocks
    }

    private func cleanCodeLine(_ line: String) -> String {
        var cleaned = line
        if let commentIndex = cleaned.range(of: "//")?.lowerBound {
            cleaned = String(cleaned[..<commentIndex])
        }
        cleaned = cleaned.replacingOccurrences(of: "\"[^\"]*\"", with: "\"\"", options: .regularExpression)
        return cleaned
    }

    private func findHeaderLineText(in lines: NSMutableArray, upTo lineIndex: Int) -> String {
        guard lineIndex >= 0, lineIndex < lines.count else { return "" }
        
        var combinedText = ""
        var lookback = lineIndex
        
        while lookback >= 0 && lookback >= lineIndex - 5 {
            if let str = lines[lookback] as? String {
                let cleaned = cleanCodeLine(str).trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    combinedText = cleaned + " " + combinedText
                    let lower = combinedText.lowercased()
                    if lower.contains("func ") || lower.contains("struct ") || lower.contains("class ") ||
                       lower.contains("enum ") || lower.contains("actor ") || lower.contains("protocol ") ||
                       lower.contains("var ") || lower.contains("let ") || lower.contains("init") {
                        break
                    }
                }
            }
            lookback -= 1
        }
        
        return combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func identifyContext(from lineText: String) -> String {
        let trimmed = lineText.trimmingCharacters(in: .whitespacesAndNewlines)

        if let match = firstRegexMatch(pattern: "\\bstruct\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "struct \(match)"
        }
        if trimmed.contains("struct ") { return "struct" }

        if let match = firstRegexMatch(pattern: "\\bclass\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "class \(match)"
        }
        if trimmed.contains("class ") { return "class" }

        if let match = firstRegexMatch(pattern: "\\benum\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "enum \(match)"
        }
        if trimmed.contains("enum ") { return "enum" }

        if let match = firstRegexMatch(pattern: "\\bactor\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "actor \(match)"
        }
        if trimmed.contains("actor ") { return "actor" }

        if let match = firstRegexMatch(pattern: "\\bprotocol\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "protocol \(match)"
        }
        if trimmed.contains("protocol ") { return "protocol" }

        if let match = firstRegexMatch(pattern: "\\bfunc\\s+([A-Za-z0-9_]+)", in: trimmed) {
            return "function \(match)"
        }
        if trimmed.contains("func ") { return "function" }

        if trimmed.contains("for ") || trimmed.contains("forEach") { return "for loop" }
        if trimmed.contains("while ") { return "while loop" }
        if trimmed.contains("repeat ") { return "repeat-while loop" }

        if trimmed.contains("if ") || trimmed.contains("else if") { return "if statement" }
        if trimmed.contains("else") { return "else statement" }
        if trimmed.contains("guard ") { return "guard statement" }
        if trimmed.contains("switch ") { return "switch statement" }

        if let match = firstRegexMatch(pattern: "\\b(var|let)\\s+([A-Za-z0-9_]+)", in: trimmed, captureGroup: 2) {
            return "property \(match)"
        }

        if trimmed.contains("init") { return "initializer" }

        if let match = firstRegexMatch(pattern: "([A-Za-z0-9_]+)\\s*\\{", in: trimmed) {
            return "\(match) block"
        }

        return "block"
    }

    private func firstRegexMatch(pattern: String, in text: String, captureGroup: Int = 1) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let nsRange = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, options: [], range: nsRange) {
            if match.numberOfRanges > captureGroup, let range = Range(match.range(at: captureGroup), in: text) {
                return String(text[range])
            }
        }
        return nil
    }

    private func count(pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return 0 }
        let range = NSRange(text.startIndex..., in: text)
        return regex.numberOfMatches(in: text, options: [], range: range)
    }

    // MARK: - Speech Handling
    
    private func speak(message: String) {
        let utterance = AVSpeechUtterance(string: message)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = 0.48
        synthesizer.speak(utterance)jy5ffd
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        commandCompletion?(nil)
    }
}
