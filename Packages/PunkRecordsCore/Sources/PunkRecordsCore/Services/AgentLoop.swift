import Foundation

/// Iterative tool-call loop: sends a prompt to the LLM, executes any tool calls
/// in the response, feeds results back, and repeats until the LLM stops calling tools
/// or the iteration limit is reached.
public actor AgentLoop {
    private let provider: any LLMProvider
    private let contextBuilder: ContextBuilder
    private let tools: [String: any AgentTool]
    private let maxIterations: Int
    private let vaultName: String

    public init(
        provider: any LLMProvider,
        contextBuilder: ContextBuilder,
        tools: [any AgentTool],
        maxIterations: Int = 10,
        vaultName: String
    ) {
        self.provider = provider
        self.contextBuilder = contextBuilder
        self.tools = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
        self.maxIterations = maxIterations
        self.vaultName = vaultName
    }

    /// Run the agent loop, returning a stream of events for the UI.
    /// Pass `systemPromptTemplate` to override the default ContextBuilder prompt for A/B eval testing.
    /// Pass `enableWebSearch: true` to attach the provider's native web search server tool
    /// (currently Anthropic-only; other providers silently ignore it).
    public func run(
        prompt: String,
        scope: QueryScope,
        currentDocumentID: DocumentID?,
        selectedText: String?,
        systemPromptTemplate: String? = nil,
        enableWebSearch: Bool = false
    ) -> AsyncThrowingStream<AgentEvent, Error> {
        let provider = self.provider
        let contextBuilder = self.contextBuilder
        let tools = self.tools
        let maxIterations = self.maxIterations
        let vaultName = self.vaultName

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.executeLoop(
                        prompt: prompt,
                        scope: scope,
                        currentDocumentID: currentDocumentID,
                        selectedText: selectedText,
                        provider: provider,
                        contextBuilder: contextBuilder,
                        tools: tools,
                        maxIterations: maxIterations,
                        vaultName: vaultName,
                        systemPromptTemplate: systemPromptTemplate,
                        enableWebSearch: enableWebSearch,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    continuation.yield(.error(.cancelled))
                    continuation.finish()
                } catch {
                    continuation.yield(.error(.providerError(error.localizedDescription)))
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func executeLoop(
        prompt: String,
        scope: QueryScope,
        currentDocumentID: DocumentID?,
        selectedText: String?,
        provider: any LLMProvider,
        contextBuilder: ContextBuilder,
        tools: [String: any AgentTool],
        maxIterations: Int,
        vaultName: String,
        systemPromptTemplate: String?,
        enableWebSearch: Bool,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws {
        continuation.yield(.agentStart)

        // Build vault context (same as the Q&A path, with optional prompt template override)
        let maxTokens = await provider.maxContextTokens
        let (systemPrompt, excerpts) = try await contextBuilder.buildContext(
            prompt: prompt,
            scope: scope,
            currentDocumentID: currentDocumentID,
            maxTokens: maxTokens,
            vaultName: vaultName,
            systemPromptTemplate: systemPromptTemplate
        )

        // Build tool definitions
        let toolDefs = tools.values.map { tool in
            ToolDefinition(
                name: tool.name,
                description: tool.description,
                inputSchema: tool.parameterSchema.toJSONSchema()
            )
        }

        // Initialize conversation with user message
        var conversationMessages: [ConversationMessage] = []
        let userContent: String
        if let sel = selectedText {
            userContent = "Selected text: \(sel)\n\n\(prompt)"
        } else {
            userContent = prompt
        }
        conversationMessages.append(ConversationMessage(role: .user, content: [.text(userContent)]))

        var finalText = ""

        let serverTools: [ServerToolConfig]? = enableWebSearch ? [.webSearch(maxUses: 5)] : nil

        for turnIndex in 0..<maxIterations {
            try Task.checkCancellation()
            continuation.yield(.turnStart(turnIndex: turnIndex))

            // Build request with full conversation history and tool definitions
            let request = LLMRequest(
                userPrompt: prompt,
                systemPrompt: systemPrompt,
                contextDocuments: excerpts,
                streamResponse: false,
                tools: toolDefs,
                messages: conversationMessages,
                serverTools: serverTools
            )

            let response = try await provider.completeWithTools(request)

            // Emit events in document order so server-tool calls appear between
            // text segments rather than after them.
            var serverToolNames: [String: String] = [:]
            for block in response.contentBlocks {
                switch block {
                case .text(let token):
                    if !token.isEmpty {
                        continuation.yield(.textToken(token))
                        finalText += token
                    }
                case .serverToolUse(let id, let name, let input):
                    serverToolNames[id] = name
                    continuation.yield(.toolStart(
                        name: name,
                        arguments: Self.encodeArgs(input.toPlainDict())
                    ))
                case .serverToolResult(let toolUseID, let content, let isError):
                    let name = serverToolNames[toolUseID] ?? "web_search"
                    continuation.yield(.toolEnd(
                        name: name,
                        result: ToolResult(content: content, isError: isError)
                    ))
                case .toolUse, .toolResult:
                    // Local tool calls are handled in the second pass below so we
                    // can also dispatch their execution; tool_result blocks only
                    // appear in messages we *send*, not in responses we receive.
                    break
                }
            }

            // If the LLM stopped without requesting a (local) tool, we're done
            if response.stopReason == .endTurn || response.stopReason == .maxTokens {
                continuation.yield(.turnEnd(turnIndex: turnIndex))
                continuation.yield(.done(finalText: finalText))
                continuation.finish()
                return
            }

            guard response.stopReason == .toolUse else {
                continuation.yield(.turnEnd(turnIndex: turnIndex))
                continuation.yield(.done(finalText: finalText))
                continuation.finish()
                return
            }

            // Append assistant response (including tool_use blocks) to conversation
            conversationMessages.append(ConversationMessage(
                role: .assistant,
                content: response.contentBlocks
            ))

            // Execute each local tool call and collect results
            var toolResultBlocks: [ContentBlock] = []

            for toolCall in response.toolUseBlocks {
                try Task.checkCancellation()

                continuation.yield(.toolStart(
                    name: toolCall.name,
                    arguments: Self.encodeArgs(toolCall.input.toPlainDict())
                ))

                let result: ToolResult
                if let tool = tools[toolCall.name] {
                    do {
                        result = try await tool.execute(arguments: toolCall.input.toPlainDict())
                    } catch {
                        result = ToolResult(
                            content: "Error: \(error.localizedDescription)",
                            isError: true
                        )
                    }
                } else {
                    result = ToolResult(
                        content: "Tool '\(toolCall.name)' not found",
                        isError: true
                    )
                }

                continuation.yield(.toolEnd(name: toolCall.name, result: result))
                toolResultBlocks.append(.toolResult(
                    toolUseID: toolCall.id,
                    content: result.content,
                    isError: result.isError
                ))
            }

            // Append tool results as a user message (Anthropic API format)
            conversationMessages.append(ConversationMessage(
                role: .user,
                content: toolResultBlocks
            ))

            continuation.yield(.turnEnd(turnIndex: turnIndex))
        }

        // Hit max iterations
        continuation.yield(.error(.maxIterationsExceeded(maxIterations)))
        continuation.yield(.done(finalText: finalText))
        continuation.finish()
    }

    /// JSON-encode tool arguments as a stable string. Falls back to "{}" if the
    /// dict isn't JSON-serialisable for some reason.
    private static func encodeArgs(_ args: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: args,
            options: [.sortedKeys]
        ), let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}
