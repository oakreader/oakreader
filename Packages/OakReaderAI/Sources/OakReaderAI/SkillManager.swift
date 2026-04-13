import Foundation

public final class SkillManager: Sendable {
    public static let shared = SkillManager()

    public let builtInSkills: [Skill] = [
        Skill(
            id: "summarize",
            name: "Summarize",
            description: "Concise document summary",
            systemPrompt: """
                You are a document summarization assistant. Provide a clear, concise summary of the provided PDF content. \
                Focus on key points, main arguments, and conclusions. Structure the summary with bullet points when appropriate.
                """,
            icon: "doc.text.magnifyingglass",
            contextMode: .fullDocument
        ),
        Skill(
            id: "extract",
            name: "Extract Info",
            description: "Key dates, names, figures, conclusions",
            systemPrompt: """
                You are an information extraction assistant. Extract and organize key information from the document including: \
                dates, names, figures, statistics, conclusions, and action items. Present them in a structured format.
                """,
            icon: "list.clipboard",
            contextMode: .fullDocument
        ),
        Skill(
            id: "explain",
            name: "Explain",
            description: "Simplify current page content",
            systemPrompt: """
                You are an explanation assistant. Explain the content of the current page in simple, clear language. \
                Break down complex concepts, define technical terms, and use analogies where helpful.
                """,
            icon: "lightbulb",
            contextMode: .currentPage
        ),
        Skill(
            id: "translate",
            name: "Translate",
            description: "Translate to target language",
            systemPrompt: """
                You are a translation assistant. Translate the provided text accurately while preserving meaning, tone, \
                and formatting. If the user doesn't specify a target language, ask them which language they'd like.
                """,
            icon: "globe",
            contextMode: .currentPage
        ),
        Skill(
            id: "find",
            name: "Find Info",
            description: "Search for specific information",
            systemPrompt: """
                You are a document search assistant. Help the user find specific information within the document. \
                Quote relevant passages and cite page numbers when possible.
                """,
            icon: "magnifyingglass",
            contextMode: .fullDocument
        ),
        Skill(
            id: "compare",
            name: "Compare",
            description: "Compare/contrast document sections",
            systemPrompt: """
                You are a comparison assistant. Compare and contrast different sections or aspects of the document. \
                Identify similarities, differences, and patterns. Present findings in a clear structured format.
                """,
            icon: "arrow.left.arrow.right",
            contextMode: .fullDocument
        ),
        Skill(
            id: "annotate",
            name: "Suggest Annotations",
            description: "Recommend highlights and notes",
            systemPrompt: """
                You are an annotation assistant. Analyze the current page and suggest specific text that should be \
                highlighted, key passages worth noting, and areas where comments would be valuable. \
                Format suggestions as actionable items.
                """,
            icon: "pencil.and.outline",
            contextMode: .currentPage
        ),
        Skill(
            id: "qa",
            name: "Q&A",
            description: "Answer questions from document text",
            systemPrompt: """
                You are a document Q&A assistant. Answer the user's questions based on the document content. \
                Always ground your answers in the actual document text. If the answer isn't in the document, say so. \
                Quote relevant passages to support your answers.
                """,
            icon: "questionmark.bubble",
            contextMode: .fullDocument
        ),
    ]

    public func skill(byId id: String) -> Skill? {
        builtInSkills.first { $0.id == id }
    }

    private init() {}
}
