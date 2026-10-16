# spec/sse_spec.cr
require "./spec_helper"
require "../src/llm-ai"

private def sse_reader(input : String)
  LLM::AI::SSE::Reader.new(IO::Memory.new(input))
end

private class OneByteIO < IO
  def initialize(@inner : IO)
  end

  def read(slice : Bytes) : Int32
    @inner.read(slice[0, 1])
  end

  def write(slice : Bytes) : Nil
  end
end

describe LLM::AI::SSE::Reader do
  it "parses data-only events" do
    reader = sse_reader("data: {\"a\":1}\n\n")
    event = reader.next
    event.should_not be_nil
    event.not_nil!.data.should eq("{\"a\":1}")
    reader.next.should be_nil
  end

  it "parses multi-line data joined by newline" do
    event = sse_reader("data: a\ndata: b\n\n").next
    event.should_not be_nil
    event.not_nil!.data.should eq("a\nb")
  end

  it "ignores comment lines" do
    sse_reader(": ping\n\n").next.should be_nil
  end

  it "handles CRLF" do
    event = sse_reader("data: x\r\n\r\n").next
    event.should_not be_nil
    event.not_nil!.data.should eq("x")
  end

  it "flushes a trailing event without blank line" do
    event = sse_reader("data: x").next
    event.should_not be_nil
    event.not_nil!.data.should eq("x")
  end

  it "captures event name" do
    event = sse_reader("event: error\ndata: boom\n\n").next
    event.should_not be_nil
    event.not_nil!.name.should eq("error")
    event.not_nil!.data.should eq("boom")
  end

  it "preserves multibyte data" do
    event = sse_reader("data: 日本語テスト\n\n").next
    event.should_not be_nil
    event.not_nil!.data.should eq("日本語テスト")
  end

  it "preserves multibyte data through one-byte reads" do
    reader = LLM::AI::SSE::Reader.new(OneByteIO.new(IO::Memory.new("data: 日本語テスト\n\n")))
    event = reader.next
    event.should_not be_nil
    event.not_nil!.data.should eq("日本語テスト")
  end

  it "terminates after events with id lines" do
    reader = sse_reader("id: 1\ndata: x")
    event = reader.next
    event.should_not be_nil
    event.not_nil!.data.should eq("x")
    reader.next.should be_nil

    sse_reader("id: 1\n\n").next.should be_nil
  end
end
