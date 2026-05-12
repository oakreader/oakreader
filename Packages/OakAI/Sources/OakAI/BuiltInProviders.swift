import Foundation

public enum BuiltInProviders {
    static func registerAll(in registry: ProviderRegistry) {
        // Major cloud providers
        registry.register(anthropic)
        registry.register(openai)
        registry.register(google)
        // API-key providers
        registry.register(deepseek)
        registry.register(groq)
        registry.register(xai)
        registry.register(openRouter)
        registry.register(mistral)
        registry.register(kimi)
        registry.register(fireworks)
        registry.register(cerebras)
        registry.register(huggingFace)
        registry.register(together)
        registry.register(minimax)
        registry.register(zai)
        registry.register(opencode)
        registry.register(xiaomi)
        registry.register(kimiCoding)
        // OAuth providers
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
            ModelInfo(id: "claude-opus-4-7", name: "Claude Opus 4.7", providerId: "anthropic", contextWindow: 1_000_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", providerId: "anthropic", contextWindow: 1_000_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-opus-4-6", name: "Claude Opus 4.6", providerId: "anthropic", contextWindow: 1_000_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", providerId: "anthropic", contextWindow: 200_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-sonnet-4-5-20250929", name: "Claude Sonnet 4.5 (20250929)", providerId: "anthropic", contextWindow: 200_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-opus-4-5", name: "Claude Opus 4.5", providerId: "anthropic", contextWindow: 200_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-opus-4-5-20251101", name: "Claude Opus 4.5 (20251101)", providerId: "anthropic", contextWindow: 200_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-sonnet-4-0", name: "Claude Sonnet 4", providerId: "anthropic", contextWindow: 200_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4 (20250514)", providerId: "anthropic", contextWindow: 200_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-opus-4-1", name: "Claude Opus 4.1", providerId: "anthropic", contextWindow: 200_000, maxTokens: 32_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-opus-4-1-20250805", name: "Claude Opus 4.1 (20250805)", providerId: "anthropic", contextWindow: 200_000, maxTokens: 32_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-opus-4-0", name: "Claude Opus 4", providerId: "anthropic", contextWindow: 200_000, maxTokens: 32_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-opus-4-20250514", name: "Claude Opus 4 (20250514)", providerId: "anthropic", contextWindow: 200_000, maxTokens: 32_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", providerId: "anthropic", contextWindow: 200_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-haiku-4-5-20251001", name: "Claude Haiku 4.5 (20251001)", providerId: "anthropic", contextWindow: 200_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
        ],
        authStrategy: .apiKey(envVar: "ANTHROPIC_API_KEY")
    )

    // MARK: - OpenAI

    public static let openai = ProviderInfo(
        id: "openai",
        displayName: "OpenAI",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
        defaultModelId: "gpt-4.1",
        models: [
            // GPT-5.x series
            ModelInfo(id: "gpt-5.5", name: "GPT-5.5", providerId: "openai", contextWindow: 272_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.5-pro", name: "GPT-5.5 Pro", providerId: "openai", contextWindow: 1_050_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.4", name: "GPT-5.4", providerId: "openai", contextWindow: 272_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.4-mini", name: "GPT-5.4 mini", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.4-nano", name: "GPT-5.4 nano", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.4-pro", name: "GPT-5.4 Pro", providerId: "openai", contextWindow: 1_050_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.3-codex", name: "GPT-5.3 Codex", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.2", name: "GPT-5.2", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.2-codex", name: "GPT-5.2 Codex", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.2-pro", name: "GPT-5.2 Pro", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.1", name: "GPT-5.1", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.1-codex", name: "GPT-5.1 Codex", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.1-codex-mini", name: "GPT-5.1 Codex mini", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            // GPT-5 base
            ModelInfo(id: "gpt-5", name: "GPT-5", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5-mini", name: "GPT-5 Mini", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5-nano", name: "GPT-5 Nano", providerId: "openai", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5-pro", name: "GPT-5 Pro", providerId: "openai", contextWindow: 400_000, maxTokens: 272_000, reasoning: true, supportsVision: true),
            // GPT-4.1 series
            ModelInfo(id: "gpt-4.1", name: "GPT-4.1", providerId: "openai", contextWindow: 1_047_576, maxTokens: 32_768, reasoning: false, supportsVision: true),
            ModelInfo(id: "gpt-4.1-mini", name: "GPT-4.1 mini", providerId: "openai", contextWindow: 1_047_576, maxTokens: 32_768, reasoning: false, supportsVision: true),
            ModelInfo(id: "gpt-4.1-nano", name: "GPT-4.1 nano", providerId: "openai", contextWindow: 1_047_576, maxTokens: 32_768, reasoning: false, supportsVision: true),
            // o-series (reasoning)
            ModelInfo(id: "o4-mini", name: "o4-mini", providerId: "openai", contextWindow: 200_000, maxTokens: 100_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "o3", name: "o3", providerId: "openai", contextWindow: 200_000, maxTokens: 100_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "o3-mini", name: "o3-mini", providerId: "openai", contextWindow: 200_000, maxTokens: 100_000, reasoning: true, supportsVision: false),
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
            ModelInfo(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", providerId: "google", contextWindow: 1_048_576, maxTokens: 65_536, reasoning: true, supportsVision: true),
            ModelInfo(id: "gemini-2.5-flash", name: "Gemini 2.5 Flash", providerId: "google", contextWindow: 1_048_576, maxTokens: 65_536, reasoning: true, supportsVision: true),
            ModelInfo(id: "gemini-2.5-flash-lite", name: "Gemini 2.5 Flash Lite", providerId: "google", contextWindow: 1_048_576, maxTokens: 65_536, reasoning: true, supportsVision: true),
            ModelInfo(id: "gemini-2.0-flash", name: "Gemini 2.0 Flash", providerId: "google", contextWindow: 1_048_576, maxTokens: 8_192, reasoning: false, supportsVision: true),
            ModelInfo(id: "gemini-2.0-flash-lite", name: "Gemini 2.0 Flash Lite", providerId: "google", contextWindow: 1_048_576, maxTokens: 8_192, reasoning: false, supportsVision: true),
        ],
        authStrategy: .apiKey(envVar: "GEMINI_API_KEY")
    )

    // MARK: - DeepSeek

    public static let deepseek = ProviderInfo(
        id: "deepseek",
        displayName: "DeepSeek",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.deepseek.com/v1/chat/completions")!,
        defaultModelId: "deepseek-v4-pro",
        models: [
            ModelInfo(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", providerId: "deepseek", contextWindow: 1_000_000, maxTokens: 384_000, reasoning: true, supportsVision: false),
            ModelInfo(id: "deepseek-v4-flash", name: "DeepSeek V4 Flash", providerId: "deepseek", contextWindow: 1_000_000, maxTokens: 384_000, reasoning: true, supportsVision: false),
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
            ModelInfo(id: "llama-3.3-70b-versatile", name: "Llama 3.3 70B", providerId: "groq", contextWindow: 131_072, maxTokens: 32_768, reasoning: false, supportsVision: false),
            ModelInfo(id: "llama-3.1-8b-instant", name: "Llama 3.1 8B Instant", providerId: "groq", contextWindow: 131_072, maxTokens: 131_072, reasoning: false, supportsVision: false),
            ModelInfo(id: "meta-llama/llama-4-maverick-17b-128e-instruct", name: "Llama 4 Maverick 17B", providerId: "groq", contextWindow: 131_072, maxTokens: 8_192, reasoning: false, supportsVision: true),
            ModelInfo(id: "deepseek-r1-distill-llama-70b", name: "DeepSeek R1 Distill 70B", providerId: "groq", contextWindow: 131_072, maxTokens: 8_192, reasoning: true, supportsVision: false),
            ModelInfo(id: "groq/compound", name: "Compound", providerId: "groq", contextWindow: 131_072, maxTokens: 8_192, reasoning: true, supportsVision: false),
            ModelInfo(id: "groq/compound-mini", name: "Compound Mini", providerId: "groq", contextWindow: 131_072, maxTokens: 8_192, reasoning: true, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "GROQ_API_KEY")
    )

    // MARK: - xAI

    public static let xai = ProviderInfo(
        id: "xai",
        displayName: "xAI",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.x.ai/v1/chat/completions")!,
        defaultModelId: "grok-2",
        models: [
            ModelInfo(id: "grok-2", name: "Grok 2", providerId: "xai", contextWindow: 131_072, maxTokens: 8_192, reasoning: false, supportsVision: false),
            ModelInfo(id: "grok-2-latest", name: "Grok 2 Latest", providerId: "xai", contextWindow: 131_072, maxTokens: 8_192, reasoning: false, supportsVision: false),
            ModelInfo(id: "grok-2-1212", name: "Grok 2 (1212)", providerId: "xai", contextWindow: 131_072, maxTokens: 8_192, reasoning: false, supportsVision: false),
            ModelInfo(id: "grok-2-vision", name: "Grok 2 Vision", providerId: "xai", contextWindow: 8_192, maxTokens: 4_096, reasoning: false, supportsVision: true),
            ModelInfo(id: "grok-2-vision-latest", name: "Grok 2 Vision Latest", providerId: "xai", contextWindow: 8_192, maxTokens: 4_096, reasoning: false, supportsVision: true),
            ModelInfo(id: "grok-2-vision-1212", name: "Grok 2 Vision (1212)", providerId: "xai", contextWindow: 8_192, maxTokens: 4_096, reasoning: false, supportsVision: true),
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
            ModelInfo(id: "anthropic/claude-opus-4", name: "Claude Opus 4", providerId: "openrouter", contextWindow: 200_000, maxTokens: 32_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "openai/gpt-4.1", name: "GPT-4.1", providerId: "openrouter", contextWindow: 1_047_576, maxTokens: 32_768, reasoning: false, supportsVision: true),
            ModelInfo(id: "openai/gpt-5", name: "GPT-5", providerId: "openrouter", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "google/gemini-2.5-flash", name: "Gemini 2.5 Flash", providerId: "openrouter", contextWindow: 1_048_576, maxTokens: 65_536, reasoning: true, supportsVision: true),
            ModelInfo(id: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro", providerId: "openrouter", contextWindow: 1_000_000, maxTokens: 384_000, reasoning: true, supportsVision: false),
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
            ModelInfo(id: "mistral-large-latest", name: "Mistral Large", providerId: "mistral", contextWindow: 262_144, maxTokens: 262_144, reasoning: false, supportsVision: true),
            ModelInfo(id: "mistral-large-2512", name: "Mistral Large (2512)", providerId: "mistral", contextWindow: 262_144, maxTokens: 262_144, reasoning: false, supportsVision: true),
            ModelInfo(id: "magistral-medium-latest", name: "Magistral Medium", providerId: "mistral", contextWindow: 128_000, maxTokens: 16_384, reasoning: true, supportsVision: false),
            ModelInfo(id: "magistral-small", name: "Magistral Small", providerId: "mistral", contextWindow: 128_000, maxTokens: 128_000, reasoning: true, supportsVision: false),
            ModelInfo(id: "devstral-medium-latest", name: "Devstral Medium", providerId: "mistral", contextWindow: 262_144, maxTokens: 262_144, reasoning: false, supportsVision: false),
            ModelInfo(id: "devstral-small-2507", name: "Devstral Small", providerId: "mistral", contextWindow: 128_000, maxTokens: 128_000, reasoning: false, supportsVision: false),
            ModelInfo(id: "codestral-latest", name: "Codestral", providerId: "mistral", contextWindow: 256_000, maxTokens: 4_096, reasoning: false, supportsVision: false),
            ModelInfo(id: "ministral-8b-latest", name: "Ministral 8B", providerId: "mistral", contextWindow: 128_000, maxTokens: 128_000, reasoning: false, supportsVision: false),
            ModelInfo(id: "ministral-3b-latest", name: "Ministral 3B", providerId: "mistral", contextWindow: 128_000, maxTokens: 128_000, reasoning: false, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "MISTRAL_API_KEY")
    )

    // MARK: - Moonshot AI (Kimi)

    public static let kimi = ProviderInfo(
        id: "kimi",
        displayName: "Moonshot AI",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.moonshot.ai/v1/chat/completions")!,
        defaultModelId: "kimi-k2-thinking",
        models: [
            ModelInfo(id: "kimi-k2.5", name: "Kimi K2.5", providerId: "kimi", contextWindow: 262_144, maxTokens: 262_144, reasoning: true, supportsVision: true),
            ModelInfo(id: "kimi-k2-thinking", name: "Kimi K2 Thinking", providerId: "kimi", contextWindow: 262_144, maxTokens: 262_144, reasoning: true, supportsVision: false),
            ModelInfo(id: "kimi-k2-thinking-turbo", name: "Kimi K2 Thinking Turbo", providerId: "kimi", contextWindow: 262_144, maxTokens: 262_144, reasoning: true, supportsVision: false),
            ModelInfo(id: "kimi-k2-turbo-preview", name: "Kimi K2 Turbo", providerId: "kimi", contextWindow: 262_144, maxTokens: 262_144, reasoning: false, supportsVision: false),
            ModelInfo(id: "kimi-k2-0905-preview", name: "Kimi K2 0905", providerId: "kimi", contextWindow: 262_144, maxTokens: 262_144, reasoning: false, supportsVision: false),
            ModelInfo(id: "kimi-k2-0711-preview", name: "Kimi K2 0711", providerId: "kimi", contextWindow: 131_072, maxTokens: 16_384, reasoning: false, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "MOONSHOT_API_KEY")
    )

    // MARK: - Fireworks

    public static let fireworks = ProviderInfo(
        id: "fireworks",
        displayName: "Fireworks",
        apiFormat: .anthropicMessages,
        baseURL: URL(string: "https://api.fireworks.ai/inference/v1/messages")!,
        defaultModelId: "accounts/fireworks/models/glm-4p5",
        models: [
            ModelInfo(id: "accounts/fireworks/models/deepseek-v4-pro", name: "DeepSeek V4 Pro", providerId: "fireworks", contextWindow: 1_000_000, maxTokens: 384_000, reasoning: true, supportsVision: false),
            ModelInfo(id: "accounts/fireworks/models/deepseek-v3p2", name: "DeepSeek V3.2", providerId: "fireworks", contextWindow: 160_000, maxTokens: 160_000, reasoning: true, supportsVision: false),
            ModelInfo(id: "accounts/fireworks/models/deepseek-v3p1", name: "DeepSeek V3.1", providerId: "fireworks", contextWindow: 163_840, maxTokens: 163_840, reasoning: true, supportsVision: false),
            ModelInfo(id: "accounts/fireworks/models/glm-4p7", name: "GLM 4.7", providerId: "fireworks", contextWindow: 198_000, maxTokens: 198_000, reasoning: true, supportsVision: false),
            ModelInfo(id: "accounts/fireworks/models/glm-4p5", name: "GLM 4.5", providerId: "fireworks", contextWindow: 131_072, maxTokens: 131_072, reasoning: true, supportsVision: false),
            ModelInfo(id: "accounts/fireworks/models/glm-4p5-air", name: "GLM 4.5 Air", providerId: "fireworks", contextWindow: 131_072, maxTokens: 131_072, reasoning: true, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "FIREWORKS_API_KEY")
    )

    // MARK: - Cerebras

    public static let cerebras = ProviderInfo(
        id: "cerebras",
        displayName: "Cerebras",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.cerebras.ai/v1/chat/completions")!,
        defaultModelId: "gpt-oss-120b",
        models: [
            ModelInfo(id: "gpt-oss-120b", name: "GPT OSS 120B", providerId: "cerebras", contextWindow: 131_072, maxTokens: 32_768, reasoning: true, supportsVision: false),
            ModelInfo(id: "qwen-3-235b-a22b-instruct-2507", name: "Qwen 3 235B Instruct", providerId: "cerebras", contextWindow: 131_000, maxTokens: 32_000, reasoning: false, supportsVision: false),
            ModelInfo(id: "zai-glm-4.7", name: "ZAI GLM-4.7", providerId: "cerebras", contextWindow: 131_072, maxTokens: 40_000, reasoning: false, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "CEREBRAS_API_KEY")
    )

    // MARK: - HuggingFace

    public static let huggingFace = ProviderInfo(
        id: "huggingface",
        displayName: "Hugging Face",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://router.huggingface.co/v1/chat/completions")!,
        defaultModelId: "MiniMaxAI/MiniMax-M2.1",
        models: [
            ModelInfo(id: "MiniMaxAI/MiniMax-M2.7", name: "MiniMax-M2.7", providerId: "huggingface", contextWindow: 204_800, maxTokens: 131_072, reasoning: true, supportsVision: false),
            ModelInfo(id: "MiniMaxAI/MiniMax-M2.5", name: "MiniMax-M2.5", providerId: "huggingface", contextWindow: 204_800, maxTokens: 131_072, reasoning: true, supportsVision: false),
            ModelInfo(id: "MiniMaxAI/MiniMax-M2.1", name: "MiniMax-M2.1", providerId: "huggingface", contextWindow: 204_800, maxTokens: 131_072, reasoning: true, supportsVision: false),
            ModelInfo(id: "Qwen/Qwen3-235B-A22B-Thinking-2507", name: "Qwen3 235B Thinking", providerId: "huggingface", contextWindow: 262_144, maxTokens: 131_072, reasoning: true, supportsVision: false),
            ModelInfo(id: "Qwen/Qwen3-Coder-480B-A35B-Instruct", name: "Qwen3 Coder 480B", providerId: "huggingface", contextWindow: 262_144, maxTokens: 66_536, reasoning: false, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "HF_TOKEN")
    )

    // MARK: - Together AI

    public static let together = ProviderInfo(
        id: "together",
        displayName: "Together AI",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.together.ai/v1/chat/completions")!,
        defaultModelId: "Qwen/Qwen3-235B-A22B-Instruct-2507-tput",
        models: [
            ModelInfo(id: "Qwen/Qwen3-235B-A22B-Instruct-2507-tput", name: "Qwen3 235B Instruct", providerId: "together", contextWindow: 262_144, maxTokens: 262_144, reasoning: true, supportsVision: false),
            ModelInfo(id: "Qwen/Qwen3-Coder-480B-A35B-Instruct-FP8", name: "Qwen3 Coder 480B", providerId: "together", contextWindow: 262_144, maxTokens: 262_144, reasoning: false, supportsVision: false),
            ModelInfo(id: "MiniMaxAI/MiniMax-M2.7", name: "MiniMax-M2.7", providerId: "together", contextWindow: 202_752, maxTokens: 131_072, reasoning: true, supportsVision: false),
            ModelInfo(id: "MiniMaxAI/MiniMax-M2.5", name: "MiniMax-M2.5", providerId: "together", contextWindow: 204_800, maxTokens: 131_072, reasoning: true, supportsVision: false),
            ModelInfo(id: "deepseek-ai/DeepSeek-V3", name: "DeepSeek V3", providerId: "together", contextWindow: 131_072, maxTokens: 131_072, reasoning: true, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "TOGETHER_API_KEY")
    )

    // MARK: - MiniMax

    public static let minimax = ProviderInfo(
        id: "minimax",
        displayName: "MiniMax",
        apiFormat: .anthropicMessages,
        baseURL: URL(string: "https://api.minimax.io/anthropic/v1/messages")!,
        defaultModelId: "MiniMax-M2.7",
        models: [
            ModelInfo(id: "MiniMax-M2.7", name: "MiniMax-M2.7", providerId: "minimax", contextWindow: 204_800, maxTokens: 131_072, reasoning: true, supportsVision: false),
            ModelInfo(id: "MiniMax-M2.7-highspeed", name: "MiniMax-M2.7 Highspeed", providerId: "minimax", contextWindow: 204_800, maxTokens: 131_072, reasoning: true, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "MINIMAX_API_KEY")
    )

    // MARK: - ZAI

    public static let zai = ProviderInfo(
        id: "zai",
        displayName: "ZAI",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.z.ai/api/coding/paas/v4/chat/completions")!,
        defaultModelId: "glm-4.7",
        models: [
            ModelInfo(id: "glm-5.1", name: "GLM-5.1", providerId: "zai", contextWindow: 200_000, maxTokens: 131_072, reasoning: true, supportsVision: false),
            ModelInfo(id: "glm-5v-turbo", name: "GLM-5V-Turbo", providerId: "zai", contextWindow: 200_000, maxTokens: 131_072, reasoning: true, supportsVision: true),
            ModelInfo(id: "glm-5-turbo", name: "GLM-5-Turbo", providerId: "zai", contextWindow: 200_000, maxTokens: 131_072, reasoning: true, supportsVision: false),
            ModelInfo(id: "glm-4.7", name: "GLM-4.7", providerId: "zai", contextWindow: 204_800, maxTokens: 131_072, reasoning: true, supportsVision: false),
            ModelInfo(id: "glm-4.5-air", name: "GLM-4.5-Air", providerId: "zai", contextWindow: 131_072, maxTokens: 98_304, reasoning: true, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "ZAI_API_KEY")
    )

    // MARK: - OpenCode Zen

    public static let opencode = ProviderInfo(
        id: "opencode",
        displayName: "OpenCode Zen",
        apiFormat: .anthropicMessages,
        baseURL: URL(string: "https://opencode.ai/zen/v1/messages")!,
        defaultModelId: "claude-opus-4-6",
        models: [
            ModelInfo(id: "claude-opus-4-7", name: "Claude Opus 4.7", providerId: "opencode", contextWindow: 1_000_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-opus-4-6", name: "Claude Opus 4.6", providerId: "opencode", contextWindow: 1_000_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-opus-4-5", name: "Claude Opus 4.5", providerId: "opencode", contextWindow: 200_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-opus-4-1", name: "Claude Opus 4.1", providerId: "opencode", contextWindow: 200_000, maxTokens: 32_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-sonnet-4-6", name: "Claude Sonnet 4.6", providerId: "opencode", contextWindow: 1_000_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-sonnet-4-5", name: "Claude Sonnet 4.5", providerId: "opencode", contextWindow: 200_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-sonnet-4", name: "Claude Sonnet 4", providerId: "opencode", contextWindow: 200_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-haiku-4-5", name: "Claude Haiku 4.5", providerId: "opencode", contextWindow: 200_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "big-pickle", name: "Big Pickle", providerId: "opencode", contextWindow: 200_000, maxTokens: 128_000, reasoning: true, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "OPENCODE_API_KEY")
    )

    // MARK: - Xiaomi MiMo

    public static let xiaomi = ProviderInfo(
        id: "xiaomi",
        displayName: "Xiaomi MiMo",
        apiFormat: .anthropicMessages,
        baseURL: URL(string: "https://api.xiaomimimo.com/anthropic/v1/messages")!,
        defaultModelId: "mimo-v2-omni",
        models: [
            ModelInfo(id: "mimo-v2.5-pro", name: "MiMo-V2.5-Pro", providerId: "xiaomi", contextWindow: 1_048_576, maxTokens: 131_072, reasoning: true, supportsVision: false),
            ModelInfo(id: "mimo-v2.5", name: "MiMo-V2.5", providerId: "xiaomi", contextWindow: 1_048_576, maxTokens: 131_072, reasoning: true, supportsVision: true),
            ModelInfo(id: "mimo-v2-pro", name: "MiMo-V2-Pro", providerId: "xiaomi", contextWindow: 1_048_576, maxTokens: 131_072, reasoning: true, supportsVision: false),
            ModelInfo(id: "mimo-v2-omni", name: "MiMo-V2-Omni", providerId: "xiaomi", contextWindow: 262_144, maxTokens: 131_072, reasoning: true, supportsVision: true),
            ModelInfo(id: "mimo-v2-flash", name: "MiMo-V2-Flash", providerId: "xiaomi", contextWindow: 262_144, maxTokens: 65_536, reasoning: true, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "XIAOMI_API_KEY")
    )

    // MARK: - Kimi For Coding

    public static let kimiCoding = ProviderInfo(
        id: "kimi-coding",
        displayName: "Kimi For Coding",
        apiFormat: .anthropicMessages,
        baseURL: URL(string: "https://api.kimi.com/coding/v1/messages")!,
        defaultModelId: "kimi-for-coding",
        models: [
            ModelInfo(id: "kimi-for-coding", name: "Kimi For Coding", providerId: "kimi-coding", contextWindow: 262_144, maxTokens: 32_768, reasoning: true, supportsVision: true),
            ModelInfo(id: "kimi-k2-thinking", name: "Kimi K2 Thinking", providerId: "kimi-coding", contextWindow: 262_144, maxTokens: 32_768, reasoning: true, supportsVision: false),
        ],
        authStrategy: .apiKey(envVar: "KIMI_API_KEY")
    )

    // MARK: - OpenAI Codex (ChatGPT subscription, OAuth PKCE)

    public static let openaiCodex = ProviderInfo(
        id: "openai-codex",
        displayName: "OpenAI (ChatGPT Login)",
        apiFormat: .openaiCompletions,
        baseURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
        defaultModelId: "gpt-5.4",
        models: [
            ModelInfo(id: "gpt-5.4", name: "GPT-5.4", providerId: "openai-codex", contextWindow: 272_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.3-codex", name: "GPT-5.3 Codex", providerId: "openai-codex", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.2-codex", name: "GPT-5.2 Codex", providerId: "openai-codex", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.2", name: "GPT-5.2", providerId: "openai-codex", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.1", name: "GPT-5.1", providerId: "openai-codex", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.1-codex-max", name: "GPT-5.1 Codex Max", providerId: "openai-codex", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gpt-5.1-codex-mini", name: "GPT-5.1 Codex mini", providerId: "openai-codex", contextWindow: 400_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
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
        defaultModelId: "claude-opus-4.6",
        models: [
            ModelInfo(id: "claude-opus-4.7", name: "Claude Opus 4.7", providerId: "github-copilot", contextWindow: 144_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-opus-4.6", name: "Claude Opus 4.6", providerId: "github-copilot", contextWindow: 1_000_000, maxTokens: 64_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-sonnet-4.6", name: "Claude Sonnet 4.6", providerId: "github-copilot", contextWindow: 1_000_000, maxTokens: 32_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-sonnet-4.5", name: "Claude Sonnet 4.5", providerId: "github-copilot", contextWindow: 144_000, maxTokens: 32_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-opus-4.5", name: "Claude Opus 4.5", providerId: "github-copilot", contextWindow: 160_000, maxTokens: 32_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-sonnet-4", name: "Claude Sonnet 4", providerId: "github-copilot", contextWindow: 216_000, maxTokens: 16_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "claude-haiku-4.5", name: "Claude Haiku 4.5", providerId: "github-copilot", contextWindow: 144_000, maxTokens: 32_000, reasoning: true, supportsVision: true),
            ModelInfo(id: "gemini-2.5-pro", name: "Gemini 2.5 Pro", providerId: "github-copilot", contextWindow: 128_000, maxTokens: 64_000, reasoning: false, supportsVision: true),
            ModelInfo(id: "gpt-5", name: "GPT-5", providerId: "github-copilot", contextWindow: 128_000, maxTokens: 128_000, reasoning: true, supportsVision: true),
        ],
        authStrategy: .oauthDeviceCode(DeviceCodeConfig(
            clientId: copilotClientId,
            deviceAuthURL: URL(string: "https://github.com/login/device/code")!,
            tokenURL: URL(string: "https://github.com/login/oauth/access_token")!,
            scopes: ["read:user"]
        ))
    )
}
