package main

import (
	"context"
	"fmt"

	"github.com/anthropics/anthropic-sdk-go"
)

func main() {
	ctx := context.Background()
	client := anthropic.NewClient()

	question := "Who is André?"
	fmt.Printf("Me: %s\n", question)

	message, err := client.Messages.New(ctx, anthropic.MessageNewParams{
		MaxTokens: 1024,
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(question)),
		},
		Model: "qwen3.6-plus",
	})
	if err != nil {
		panic(err)
	}

	for _, content := range message.Content {
		switch content.Type {
		case "text":
			fmt.Printf("AI: %s\n", content.Text)
		}
	}
}
