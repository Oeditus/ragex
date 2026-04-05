defmodule Ragex.Agent.StreamConsumerTest do
  use ExUnit.Case, async: true

  alias Ragex.Agent.StreamConsumer

  describe "consume/2 - basic content accumulation" do
    test "accumulates content from stream chunks" do
      stream = [
        %{content: "Hello", thinking: nil, done: false, metadata: %{}},
        %{content: " world", thinking: nil, done: false, metadata: %{}},
        %{
          done: true,
          metadata: %{
            model: "test-model",
            usage: %{prompt_tokens: 10, completion_tokens: 5, total_tokens: 15}
          }
        }
      ]

      {:ok, response} = StreamConsumer.consume(stream)

      assert response.content == "Hello world"
      assert response.reasoning_content == nil
      assert response.tool_calls == nil
      assert response.model == "test-model"
      assert response.usage.total_tokens == 15
    end

    test "accumulates thinking content" do
      stream = [
        %{content: "", thinking: "Let me think...", done: false, metadata: %{phase: :thinking}},
        %{content: "", thinking: " about this.", done: false, metadata: %{phase: :thinking}},
        %{
          content: "The answer is 42.",
          thinking: nil,
          done: false,
          metadata: %{phase: :answering}
        },
        %{done: true, metadata: %{model: "deepseek", usage: %{}}}
      ]

      {:ok, response} = StreamConsumer.consume(stream)

      assert response.content == "The answer is 42."
      assert response.reasoning_content == "Let me think... about this."
    end

    test "handles thinking-only stream (no content)" do
      stream = [
        %{content: "", thinking: "Reasoning...", done: false, metadata: %{}},
        %{done: true, metadata: %{model: "r1", usage: %{}}}
      ]

      {:ok, response} = StreamConsumer.consume(stream)

      assert response.content == nil
      assert response.reasoning_content == "Reasoning..."
    end
  end

  describe "consume/2 - callbacks" do
    test "invokes on_chunk for each content/thinking chunk" do
      stream = [
        %{content: "A", thinking: nil, done: false, metadata: %{}},
        %{content: "B", thinking: nil, done: false, metadata: %{}},
        %{done: true, metadata: %{usage: %{}}}
      ]

      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_chunk = fn chunk ->
        Agent.update(agent, &[chunk | &1])
      end

      {:ok, _response} = StreamConsumer.consume(stream, on_chunk: on_chunk)

      chunks = Agent.get(agent, &Enum.reverse(&1))
      Agent.stop(agent)

      assert [_, _] = chunks
      assert hd(chunks).content == "A"
    end

    test "invokes on_phase on phase transitions" do
      stream = [
        %{content: "", thinking: "hmm", done: false, metadata: %{}},
        %{content: "", thinking: "more", done: false, metadata: %{}},
        %{content: "answer", thinking: nil, done: false, metadata: %{}},
        %{done: true, metadata: %{usage: %{}}}
      ]

      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_phase = fn phase ->
        Agent.update(agent, &[phase | &1])
      end

      {:ok, _response} = StreamConsumer.consume(stream, on_phase: on_phase)

      phases = Agent.get(agent, &Enum.reverse(&1))
      Agent.stop(agent)

      # Should see: :thinking (first thinking chunk), :answering (first content chunk), :done
      assert [:thinking, :answering, :done] = phases
    end

    test "does not fire duplicate phase transitions" do
      stream = [
        %{content: "A", thinking: nil, done: false, metadata: %{}},
        %{content: "B", thinking: nil, done: false, metadata: %{}},
        %{content: "C", thinking: nil, done: false, metadata: %{}},
        %{done: true, metadata: %{usage: %{}}}
      ]

      {:ok, agent} = Agent.start_link(fn -> [] end)

      on_phase = fn phase ->
        Agent.update(agent, &[phase | &1])
      end

      {:ok, _response} = StreamConsumer.consume(stream, on_phase: on_phase)

      phases = Agent.get(agent, &Enum.reverse(&1))
      Agent.stop(agent)

      # :answering should appear only once despite 3 content chunks
      assert [:answering, :done] = phases
    end
  end

  describe "consume/2 - error handling" do
    test "returns error for error chunks" do
      stream = [
        %{content: "partial", thinking: nil, done: false, metadata: %{}},
        {:error, :timeout}
      ]

      {:error, :timeout} = StreamConsumer.consume(stream)
    end

    test "handles empty stream" do
      {:ok, response} = StreamConsumer.consume([])

      assert response.content == nil
      assert response.reasoning_content == nil
      assert response.tool_calls == nil
    end
  end

  describe "consume/2 - empty content detection" do
    test "returns nil content when stream has no text (tool_call scenario)" do
      # Simulates a stream where LLM returned tool_calls (skipped by parser)
      # Only done chunk arrives with no content
      stream = [
        %{done: true, metadata: %{finish_reason: "tool_calls", usage: %{prompt_tokens: 50}}}
      ]

      {:ok, response} = StreamConsumer.consume(stream)

      assert response.content == nil
      assert response.usage.prompt_tokens == 50
    end
  end

  describe "consume/2 - usage normalization" do
    test "normalizes string-keyed usage maps" do
      stream = [
        %{content: "hi", thinking: nil, done: false, metadata: %{}},
        %{
          done: true,
          metadata: %{
            usage: %{"prompt_tokens" => 10, "completion_tokens" => 5, "total_tokens" => 15}
          }
        }
      ]

      {:ok, response} = StreamConsumer.consume(stream)

      assert response.usage.prompt_tokens == 10
      assert response.usage.completion_tokens == 5
      assert response.usage.total_tokens == 15
    end

    test "handles nil usage" do
      stream = [
        %{content: "hi", thinking: nil, done: false, metadata: %{}},
        %{done: true, metadata: %{}}
      ]

      {:ok, response} = StreamConsumer.consume(stream)

      assert response.usage.prompt_tokens == 0
      assert response.usage.completion_tokens == 0
    end
  end
end
