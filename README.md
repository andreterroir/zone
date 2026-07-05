OpenCode Go endpoints are documented
[here](https://github.com/anomalyco/opencode/blob/dev/packages/web/src/content/docs/go.mdx#endpoints).

To run with an OpenCode Go OpenAI compatible model:

	OPENAI_BASE_URL='https://opencode.ai/zen/go/v1' OPENAI_API_KEY='<redacted>' go run openai.go


To run with an OpenCode Go Anthropic compatible model:

	ANTHROPIC_BASE_URL='https://opencode.ai/zen/go' ANTHROPIC_API_KEY='<redacted>' go run anthropic.go
