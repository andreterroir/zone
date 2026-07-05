package main

import (
	"context"
	"fmt"

	"github.com/openai/openai-go/v3"
)

func main() {
	ctx := context.Background()
	client := openai.NewClient()

	question := "Who is Chloé?"
	fmt.Printf("Me: %s\n", question)

	chatCompletion, err := client.Chat.Completions.New(ctx, openai.ChatCompletionNewParams{
		Messages: []openai.ChatCompletionMessageParamUnion{
			openai.UserMessage(question),
		},
		Model: "deepseek-v4-flash",
	})
	if err != nil {
		panic(err)
	}

	fmt.Printf("AI: %s\n", chatCompletion.Choices[0].Message.Content)
}
