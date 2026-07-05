package main

import (
	"context"

	"github.com/openai/openai-go/v3"
)

func main() {
	ctx := context.Background()
	client := openai.NewClient()

	question := "What does the name Chloé mean?"

	chatCompletion, err := client.Chat.Completions.New(ctx, openai.ChatCompletionNewParams{
		Messages: []openai.ChatCompletionMessageParamUnion{
			openai.UserMessage(question),
		},
		Model: "deepseek-v4-flash",
	})
	if err != nil {
		panic(err)
	}

	println(chatCompletion.Choices[0].Message.Content)
}
