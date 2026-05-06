import Foundation

public enum BuiltInProviders {
    static func registerAll(in registry: ProviderRegistry) {
        // Original 3
        registry.register(anthropic)
        registry.register(openai)
        registry.register(google)
        // Phase 2 API-key providers
        registry.register(deepseek)
        registry.register(groq)
        registry.register(xai)
        registry.register(openRouter)
        registry.register(mistral)
        registry.register(kimi)
        registry.register(fireworks)
        registry.register(cerebras)
        registry.register(huggingFace)
        registry.register(minimax)
        // Phase 4 OAuth providers
        registry.register(openaiCodex)
        registry.register(githubCopilot)
    }

    // MARK: - Anthropic

    public static let anthropic = ProviderInfo(
        id: "anthropic",
        displayName: "Anthropic",
        apiFormat: .anthropicMessages,
        baseURL: URL(string: "https://api.anthropic.com/v1/messages")!,
        defaultModelId: "claude-sonnet-4-6",
        models: [
            ModelInfo(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", providerId: "anthropic", contextWindow: 200_000, maxTokens: 16_000, reasoning: false, supportsVision: true),
            ModelInfo(id: "claude-opus-4-6", name: "Claude Opus 4.6", providerId: "anthropic", contextWindow: 200_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-sonnet-4-5-20250929", name: "Claude Sonnet 4.5", providerId: "anthropic", contextWindow: 200_000, maxTokens: 16_000, reasoning: false, supportsVision: true),
            ModelInfo(id: "claude-opus-4-5-20251101", name: "Claude Opus 4.5", providerId: "anthropic", contextWindow: 200_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
        ],
        authStrategy: .apiKey(envVar: "ANTHROPIC_API_KEY")
    )

    // MARK: - OpenAI

    public static let openai = ProviderInfo(
        id: "openai",
        displayName: "OpenAI",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
        defaultModelId: "gpt-5.4",
        models: [
            ModelInfo(id: "gpt-5.4", name: "GPT-5.4", providerId: "openai", contextWindow: 1_000_000, maxTokens: 128_000, reasoning: false, supportsVision: true),
            ModelInfo(id: "gpt-5.4-mini", name: "GPT-5.4 mini", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: false, supportsVision: true),
            ModelInfo(id: "gpt-5.4-nano", name: "GPT-5.4 nano", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: false, supportsVision: true),
            ModelInfo(id: "gpt-4.1", name: "GPT-4.1", providerId: "openai", contextWindow: 1_000_000, maxTokens: 32_768, reasoning: false, supportsVision: true),
            ModelInfo(id: "gpt-4.1-mini", name: "GPT-4.1 mini", providerId: "openai", contextWindow: 1_000_000, maxTokens: 32_768, reasoning: false, supportsVision: true),
            ModelInfo(id: "gpt-4.1-nano", name: "GPT-4.1 nano", providerId: "openai", contextWindow: 1_000_000, maxTokens: 32_768, reasoning: false, supportsVision: true),
            ModelInfo(id: "o4-mini", name: "o4-mini", providerId: "openai", contextWindow: 200_000, maxTokens: 100_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "o3", name: "o3", providerId: "openai", contextWindow: 200_000, maxTokens: 100_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "o3-pro", name: "o3-pro", providerId: "openai", contextWindow: 200_000, maxTokens: 100_000, reasoning: true, supportsVision: true),
        ],
        authStrategy: .apiKey(envVar: "OPENAI_API_KEY")
    )

    // MARK: - Google

    public static let google = ProviderInfo(
        id: "google",
        displayName: "Google Gemini",
        apiFormat: .googleGenerativeAI,
        baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/models/")!,
        defaultModelId: "gemini-2.5-flash",
        models: [
            ModelInfo(id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro", providerId: "google", contextWindow: 1_000_000, maxTokens: 65_536, reasoning: true, supportsVision: true),
            ModelInfo(id: "gemini-3.1-flash-lite-preview", name: "Gemini 3.1 Flash Lite", providerId: "google", contextWindow: 1_000_000, maxTokens: 65_536, reasoning: false, supportsVision: true),
            ModelInfo(id: "gemini-3-pro-preview", name: "Gemini 3 Pro", providerId: "google", contextWindow: 1_000_000, maxTokens: 65_536, reasoning: true, supportsVision: true),
            ModelInfo(id: "gemini-3-flash-preview", name: "Gemini 3 Flash", providerId: "google", contextWindow: 1_000_000, maxTokens: 65_536, reasoning: false, supportsVision: true),
            ModelInfo(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", providerId: "google", contextWindow: 1_000_000, maxTokens: 65_536, reasoning: true, supportsVision: true),
            ModelInfo(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", providerId: "google", contextWindow: 1_000_000, maxTokens: 65_536, reasoning: true, supportsVision: true),
            ModelInfo(id: "gemini-2.5-flash-lite", name: "Gemini 2.5 Flash Lite", providerId: "google", contextWindow: 1_000_000, maxTokens: 65_536, reasoning: false, supportsVision: true),
        ],
        authStrategy: .apiKey(envVar: "GOOGLE_AI_API_KEY")
    )

    // MARK: - DeepSeek

    public static let deepseek = ProviderInfo(
        id: "deepseek",
        displayName: "DeepSeek",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
        defaultModelId: "deepseek-chat",
        models: [
            ModelInfo(id: "deepseek-chat", name: "DeepSeek Chat", providerId: "deepseek", contextWindow: 128_000, maxTokens: 8_192, reasoning: false, supportsVision: false),
            ModelInfo(id: "deepseek-reasoner", name: "DeepSeek Reasoner", providerId: "deepseek", contextWindow: 128_000, maxTokens: 8_192, reasoning: true, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "DEEPSEEK_API_KEY")
    )

    // MARK: - Groq

    public static let groq = ProviderInfo(
        id: "groq",
        displayName: "Groq",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.groq.com/openai/v1/chat/completions")!,
        defaultModelId: "llama-3.3-70b-versatile",
        models: [
            ModelInfo(id: "llama-3.3-70b-versatile", name: "Llama 3.3 70B", providerId: "groq", contextWindow: 128_000, maxTokens: 32_768, reasoning: false, supportsVision: false),
            ModelInfo(id: "llama-3.1-8b-instant", name: "Llama 3.1 8B", providerId: "groq", contextWindow: 128_000, maxTokens: 8_192, reasoning: false, supportsVision: false),
            ModelInfo(id: "gemma2-9b-it", name: "Gemma 2 9B", providerId: "groq", contextWindow: 8_192, maxTokens: 8_192, reasoning: false, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "GROQ_API_KEY")
    )

    // MARK: - xAI

    public static let xai = ProviderInfo(
        id: "xai",
        displayName: "xAI",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.x.ai/v1/chat/completions")!,
        defaultModelId: "grok-3",
        models: [
            ModelInfo(id: "grok-3", name: "Grok 3", providerId: "xai", contextWindow: 131_072, maxTokens: 131_072, reasoning: false, supportsVision: true),
            ModelInfo(id: "grok-3-mini", name: "Grok 3 Mini", providerId: "xai", contextWindow: 131_072, maxTokens: 131_072, reasoning: true, supportsVision: true),
        ],
        authStrategy: .apiKey(envVar: "XAI_API_KEY")
    )

    // MARK: - OpenRouter

    public static let openRouter = ProviderInfo(
        id: "openrouter",
        displayName: "OpenRouter",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
        defaultModelId: "anthropic/claude-sonnet-4",
        models: [
            ModelInfo(id: "anthropic/claude-sonnet-4", name: "Claude Sonnet 4", providerId: "openrouter", contextWindow: 200_000, maxTokens: 16_000, reasoning: false, supportsVision: true),
            ModelInfo(id: "openai/gpt-4.1", name: "GPT-4.1", providerId: "openrouter", contextWindow: 1_000_000, maxTokens: 32_768, reasoning: false, supportsVision: true),
            ModelInfo(id: "google/gemini-2.5-flash", name: "Gemini 2.5 Flash", providerId: "openrouter", contextWindow: 1_000_000, maxTokens: 65_536, reasoning: true, supportsVision: true),
        ],
        authStrategy: .apiKey(envVar: "OPENROUTER_API_KEY")
    )

    // MARK: - Mistral

    public static let mistral = ProviderInfo(
        id: "mistral",
        displayName: "Mistral",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.mistral.ai/v1/chat/completions")!,
        defaultModelId: "mistral-large-latest",
        models: [
            ModelInfo(id: "mistral-large-latest", name: "Mistral Large", providerId: "mistral", contextWindow: 128_000, maxTokens: 8_192, reasoning: false, supportsVision: true),
            ModelInfo(id: "mistral-medium-latest", name: "Mistral Medium", providerId: "mistral", contextWindow: 128_000, maxTokens: 8_192, reasoning: false, supportsVision: false),
            ModelInfo(id: "mistral-small-latest", name: "Mistral Small", providerId: "mistral", contextWindow: 128_000, maxTokens: 8_192, reasoning: false, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "MISTRAL_API_KEY")
    )

    // MARK: - Kimi (Moonshot)

    public static let kimi = ProviderInfo(
        id: "kimi",
        displayName: "Kimi",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.moonshot.cn/v1/chat/completions")!,
        defaultModelId: "moonshot-v1-auto",
        models: [
            ModelInfo(id: "moonshot-v1-auto", name: "Moonshot v1 Auto", providerId: "kimi", contextWindow: 128_000, maxTokens: 8_192, reasoning: false, supportsVision: false),
            ModelInfo(id: "moonshot-v1-128k", name: "Moonshot v1 128K", providerId: "kimi", contextWindow: 128_000, maxTokens: 8_192, reasoning: false, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "MOONSHOT_API_KEY")
    )

    // MARK: - Fireworks

    public static let fireworks = ProviderInfo(
        id: "fireworks",
        displayName: "Fireworks",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.fireworks.ai/inference/v1/chat/completions")!,
        defaultModelId: "accounts/fireworks/models/llama4-maverick-instruct-basic",
        models: [
            ModelInfo(id: "accounts/fireworks/models/llama4-maverick-instruct-basic", name: "Llama 4 Maverick", providerId: "fireworks", contextWindow: 128_000, maxTokens: 8_192, reasoning: false, supportsVision: true),
            ModelInfo(id: "accounts/fireworks/models/llama4-scout-instruct-basic", name: "Llama 4 Scout", providerId: "fireworks", contextWindow: 128_000, maxTokens: 8_192, reasoning: false, supportsVision: true),
        ],
        authStrategy: .apiKey(envVar: "FIREWORKS_API_KEY")
    )

    // MARK: - Cerebras

    public static let cerebras = ProviderInfo(
        id: "cerebras",
        displayName: "Cerebras",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.cerebras.ai/v1/chat/completions")!,
        defaultModelId: "llama-4-scout-17b-16e-instruct",
        models: [
            ModelInfo(id: "llama-4-scout-17b-16e-instruct", name: "Llama 4 Scout 17B", providerId: "cerebras", contextWindow: 128_000, maxTokens: 8_192, reasoning: false, supportsVision: false),
            ModelInfo(id: "llama3.3-70b", name: "Llama 3.3 70B", providerId: "cerebras", contextWindow: 128_000, maxTokens: 8_192, reasoning: false, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "CEREBRAS_API_KEY")
    )

    // MARK: - HuggingFace

    public static let huggingFace = ProviderInfo(
        id: "huggingface",
        displayName: "Hugging Face",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api-inference.huggingface.co/v1/chat/completions")!,
        defaultModelId: "Qwen/Qwen3-235B-A22B",
        models: [
            ModelInfo(id: "Qwen/Qwen3-235B-A22B", name: "Qwen3 235B", providerId: "huggingface", contextWindow: 131_072, maxTokens: 8_192, reasoning: true, supportsVision: false),
            ModelInfo(id: "meta-llama/Llama-3.3-70B-Instruct", name: "Llama 3.3 70B", providerId: "huggingface", contextWindow: 128_000, maxTokens: 8_192, reasoning: false, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "HF_TOKEN")
    )

    // MARK: - MiniMax

    public static let minimax = ProviderInfo(
        id: "minimax",
        displayName: "MiniMax",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.minimax.chat/v1/text/chatcompletion_v2")!,
        defaultModelId: "MiniMax-M1",
        models: [
            ModelInfo(id: "MiniMax-M1", name: "MiniMax M1", providerId: "minimax", contextWindow: 1_000_000, maxTokens: 8_192, reasoning: true, supportsVision: false),
            ModelInfo(id: "MiniMax-Text-01", name: "MiniMax Text 01", providerId: "minimax", contextWindow: 1_000_000, maxTokens: 8_192, reasoning: false, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "MINIMAX_API_KEY")
    )

    // MARK: - OpenAI Codex (ChatGPT subscription, OAuth PKCE)

    public static let openaiCodex = ProviderInfo(
        id: "openai-codex",
        displayName: "OpenAI (ChatGPT Login)",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
        defaultModelId: "gpt-5.4",
        models: [
            ModelInfo(id: "gpt-5.4", name: "GPT-5.4", providerId: "openai-codex", contextWindow: 1_000_000, maxTokens: 128_000, reasoning: false, supportsVision: true),
            ModelInfo(id: "gpt-5.4-mini", name: "GPT-5.4 mini", providerId: "openai-codex", contextWindow: 400_000, maxTokens: 128_000, reasoning: false, supportsVision: true),
            ModelInfo(id: "o4-mini", name: "o4-mini", providerId: "openai-codex", contextWindow: 200_000, maxTokens: 100_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "o3", name: "o3", providerId: "openai-codex", contextWindow: 200_000, maxTokens: 100_000, reasoning: true, supportsVision: true),
        ],
        authStrategy: .oauthPKCE(OAuthPKCEConfig(
            clientId: "app_EMoamEEZ73f0CkXaXp7hrann",
            authorizationURL: URL(string: "https://auth.openai.com/oauth/authorize")!,
            tokenURL: URL(string: "https://auth.openai.com/oauth/token")!,
            scopes: ["openid", "profile", "email", "offline_access"],
            callbackPort: 1455
        ))
    )

    // MARK: - GitHub Copilot (Copilot subscription, device code)

    /// Client ID decoded from base64: "Iv1.b507a08c87ecfe98"
    private static let copilotClientId: String = {
        let encoded = "SXYxLmI1MDdhMDhjODdlY2ZlOTg="
        return String(data: Data(base64Encoded: encoded)!, encoding: .utf8)!
    }()

    public static let githubCopilot = ProviderInfo(
        id: "github-copilot",
        displayName: "GitHub Copilot",
        apiFormat: .openaiCompletions,
        // Actual endpoint is determined at runtime from Copilot token exchange
        baseURL: URL(string: "https://api.githubcopilot.com/chat/completions")!,
        defaultModelId: "gpt-4o",
        models: [
            ModelInfo(id: "gpt-4o", name: "GPT-4o", providerId: "github-copilot", contextWindow: 128_000, maxTokens: 16_384, reasoning: false, supportsVision: true),
            ModelInfo(id: "claude-3.5-sonnet", name: "Claude 3.5 Sonnet", providerId: "github-copilot", contextWindow: 200_000, maxTokens: 8_192, reasoning: false, supportsVision: true),
        ],
        authStrategy: .oauthDeviceCode(DeviceCodeConfig(
            clientId: copilotClientId,
            deviceAuthURL: URL(string: "https://github.com/login/device/code")!,
            tokenURL: URL(string: "https://github.com/login/oauth/access_token")!,
            scopes: ["read:user"]
        ))
    )
}

