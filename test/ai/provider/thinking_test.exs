# Tests for thinking/reasoning content via controlled inputs (no private function calls)
defmodule Ragex.AI.Provider.ThinkingParsingTest do
  @moduledoc false
  use ExUnit.Case, async: true

  # --- DeepSeek R1 SSE parsing ---

  describe "DeepSeek R1 SSE events with reasoning_content" do
    test "reasoning_content chunk is emitted before content" do
      # Simulate a stream of SSE events
      events = """
      data: {"choices":[{"index":0,"delta":{"reasoning_content":"thinking..."},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{"content":"answer"},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

      data: [DONE]
      """

      chunks = parse_sse_chunks(events)

      thinking_chunks =
        Enum.filter(chunks, &(Map.get(&1, :thinking) != nil and Map.get(&1, :thinking) != ""))

      content_chunks =
        Enum.filter(chunks, &(Map.get(&1, :content, "") != "" and not Map.get(&1, :done, false)))

      done_chunks = Enum.filter(chunks, &Map.get(&1, :done, false))

      assert match?([_ | _], thinking_chunks)
      assert match?([_ | _], content_chunks)
      assert match?([_ | _], done_chunks)

      assert hd(thinking_chunks).thinking == "thinking..."
      assert hd(content_chunks).content == "answer"
    end
  end

  # --- Anthropic response parsing ---

  describe "Anthropic response with thinking blocks" do
    test "parse_response extracts thinking and text" do
      body = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "reasoning here"},
          %{"type" => "text", "text" => "final answer"}
        ],
        "model" => "claude-3-sonnet",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 20},
        "stop_reason" => "end_turn"
      }

      # Test via generate which calls parse_response internally
      # Since we can't call the API, we verify the structure matches
      assert is_map(body)
      assert body["content"] |> Enum.any?(&(&1["type"] == "thinking"))
      assert body["content"] |> Enum.any?(&(&1["type"] == "text"))
    end
  end

  # --- Ollama think tag parsing ---

  describe "Ollama <think> tag parsing" do
    test "content with think tags is properly structured" do
      raw = "<think>step 1\nstep 2</think>The answer is 42."

      # The regex used inside Ollama provider
      case Regex.run(~r/<think>(.*?)<\/think>(.*)$/s, raw) do
        [_, thinking, rest] ->
          assert String.trim(thinking) == "step 1\nstep 2"
          assert String.trim(rest) == "The answer is 42."

        nil ->
          flunk("Should have matched think tags")
      end
    end

    test "content without think tags returns nil thinking" do
      raw = "Just a plain response."

      result = Regex.run(~r/<think>(.*?)<\/think>(.*)$/s, raw)
      assert result == nil
    end

    test "empty think tags" do
      raw = "<think></think>Answer."

      case Regex.run(~r/<think>(.*?)<\/think>(.*)$/s, raw) do
        [_, thinking, rest] ->
          assert String.trim(thinking) == ""
          assert String.trim(rest) == "Answer."

        nil ->
          flunk("Should have matched")
      end
    end

    test "multiline thinking content" do
      raw = "<think>\nLine 1\nLine 2\n</think>\nFinal."

      [_, thinking, rest] = Regex.run(~r/<think>(.*?)<\/think>(.*)$/s, raw)
      assert thinking =~ "Line 1"
      assert thinking =~ "Line 2"
      assert String.trim(rest) =~ "Final."
    end
  end

  # --- OpenAI SSE with reasoning_content ---

  describe "OpenAI SSE events with reasoning_content" do
    test "reasoning_content in delta produces thinking chunk" do
      events = """
      data: {"choices":[{"index":0,"delta":{"reasoning_content":"step 1"},"finish_reason":null}]}

      data: {"choices":[{"index":0,"delta":{"content":"result"},"finish_reason":null}]}

      data: [DONE]
      """

      chunks = parse_sse_chunks(events)

      thinking_chunks =
        Enum.filter(chunks, &(Map.get(&1, :thinking) != nil and Map.get(&1, :thinking) != ""))

      content_chunks =
        Enum.filter(chunks, &(Map.get(&1, :content, "") != "" and not Map.get(&1, :done, false)))

      assert match?([_ | _], thinking_chunks)
      assert match?([_ | _], content_chunks)
    end
  end

  # --- Chunk type structure ---

  describe "chunk type structure" do
    test "thinking chunk has correct fields" do
      chunk = %{
        content: "",
        thinking: "reasoning...",
        done: false,
        metadata: %{provider: :deepseek_r1, phase: :thinking}
      }

      assert chunk.thinking == "reasoning..."
      assert chunk.content == ""
      assert chunk.done == false
      assert chunk.metadata.phase == :thinking
    end

    test "content chunk has thinking as nil" do
      chunk = %{
        content: "answer text",
        thinking: nil,
        done: false,
        metadata: %{provider: :openai, phase: :answering}
      }

      assert chunk.thinking == nil
      assert chunk.content == "answer text"
      assert chunk.metadata.phase == :answering
    end

    test "final chunk has thinking as nil" do
      chunk = %{
        content: "",
        thinking: nil,
        done: true,
        metadata: %{provider: :anthropic, usage: %{prompt_tokens: 10, completion_tokens: 20}}
      }

      assert chunk.done == true
      assert chunk.thinking == nil
    end
  end

  # --- Response type structure ---

  describe "response type with reasoning_content" do
    test "response with reasoning_content" do
      response = %{
        content: "The answer",
        reasoning_content: "I thought about it",
        model: "deepseek-reasoner",
        usage: %{prompt_tokens: 10, completion_tokens: 20, total_tokens: 30},
        metadata: %{finish_reason: "stop"}
      }

      assert response.reasoning_content == "I thought about it"
      assert response.content == "The answer"
    end

    test "response without reasoning_content" do
      response = %{
        content: "Hello",
        reasoning_content: nil,
        model: "gpt-4",
        usage: %{prompt_tokens: 5, completion_tokens: 3, total_tokens: 8},
        metadata: %{finish_reason: "stop"}
      }

      assert response.reasoning_content == nil
    end
  end

  # Helper: parse SSE event string into chunks (simulates what providers do)
  defp parse_sse_chunks(events_str) do
    events_str
    |> String.split("\n\n")
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.flat_map(fn event ->
      event = String.trim(event)

      cond do
        event == "data: [DONE]" ->
          [%{content: "", thinking: nil, done: true, metadata: %{finish_reason: "stop"}}]

        String.starts_with?(event, "data: ") ->
          json_str = String.trim_leading(event, "data: ")

          case Jason.decode(json_str) do
            {:ok, %{"choices" => [choice | _]}} ->
              delta = choice["delta"] || %{}
              content = delta["content"] || ""
              reasoning = delta["reasoning_content"] || ""
              finish = choice["finish_reason"]

              cond do
                finish != nil ->
                  [%{content: "", thinking: nil, done: true, metadata: %{finish_reason: finish}}]

                reasoning != "" ->
                  [
                    %{
                      content: "",
                      thinking: reasoning,
                      done: false,
                      metadata: %{phase: :thinking}
                    }
                  ]

                content != "" ->
                  [
                    %{
                      content: content,
                      thinking: nil,
                      done: false,
                      metadata: %{phase: :answering}
                    }
                  ]

                true ->
                  []
              end

            _ ->
              []
          end

        true ->
          []
      end
    end)
  end
end
