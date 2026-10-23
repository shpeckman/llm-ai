# src/llm-ai/rest/client.cr
require "http/formdata"

module LLM::AI::Rest
  class Client
    def initialize(@provider : Provider, @auth : Auth::AuthResult, @identity : ClientIdentity? = nil,
                   @http_options : Http::Options = Http::Options.new, @abort : AbortHandle? = nil)
    end

    def list_models : Array(RemoteModel)
      entry = endpoint(:list_models)
      RemoteModelList.from_json(request(entry)).data
    end

    def balance : Balance
      entry = endpoint(:balance)
      Balance.from_json(request(entry))
    end

    def upload_file(path : String | Path, purpose : String, expires_after_seconds : Int32? = nil) : FileObject
      entry = endpoint(:upload_file)
      body = IO::Memory.new
      content_type = ""
      HTTP::FormData.build(body) do |form|
        content_type = form.content_type
        form.field("purpose", purpose)
        if seconds = expires_after_seconds
          form.field("expires_after[anchor]", "created_at")
          form.field("expires_after[seconds]", seconds.to_s)
        end
        File.open(path) do |file|
          metadata = HTTP::FormData::FileMetadata.new(filename: File.basename(path.to_s))
          form.file("file", file, metadata)
        end
      end
      FileObject.from_json(request(entry, body.to_s, content_type))
    end

    def list_files : Array(FileObject)
      entry = endpoint(:list_files)
      FileList.from_json(request(entry)).data
    end

    def get_file(file_id : String) : FileObject
      entry = endpoint(:get_file)
      FileObject.from_json(request(entry, path: "#{entry.path}/#{file_id}"))
    end

    def delete_file(file_id : String) : FileDelete
      entry = endpoint(:delete_file)
      FileDelete.from_json(request(entry, path: "#{entry.path}/#{file_id}"))
    end

    def file_content(file_id : String) : String
      entry = endpoint(:file_content)
      request(entry, path: "#{entry.path}/#{file_id}/content")
    end

    def estimate_tokens(model : Model, context : Context) : TokenEstimate
      entry = endpoint(:estimate_tokens)
      payload = JSON.build do |json|
        json.object do
          json.field "model", model.id
          json.field "messages" do
            json.array do
              if prompt = context.system_prompt
                estimate_message(json, "system", prompt) unless prompt.empty?
              end
              context.messages.each { |message| estimate_message(json, message) }
            end
          end
        end
      end
      TokenEstimate.from_json(request(entry, payload))
    end

    def verify_signature(nonce : String, timestamp : Int64, model : String, signature : String) : SignatureVerification
      entry = endpoint(:verify_signature)
      payload = JSON.build do |json|
        json.object do
          json.field "nonce", nonce
          json.field "timestamp", timestamp
          json.field "model", model
          json.field "signature", signature
        end
      end
      SignatureVerification.from_json(request(entry, payload))
    end

    def web_search(query : String, timeout_seconds : Int32? = nil, limit : Int32? = nil, include_content : Bool? = nil) : Array(SearchResult)
      entry = endpoint(:web_search)
      payload = JSON.build do |json|
        json.object do
          json.field "text_query", query
          json.field "timeout_seconds", timeout_seconds if timeout_seconds
          json.field "limit", limit if limit
          json.field "include_content", include_content unless include_content.nil?
        end
      end
      SearchResults.from_json(request(entry, payload)).search_results
    end

    def web_search_pro(query : String, timeout_seconds : Int32? = nil, limit : Int32? = nil,
                       sites : Array(String)? = nil, time_window : Tuple(String?, String?)? = nil) : Array(SearchProResult)
      entry = endpoint(:web_search_pro)
      payload = JSON.build do |json|
        json.object do
          json.field "text_query", query
          json.field "timeout_seconds", timeout_seconds if timeout_seconds
          json.field "limit", limit if limit
          json.field "sites", sites if sites
          if window = time_window
            json.field "time_window" do
              json.object do
                json.field "start", window[0] if window[0]
                json.field "end", window[1] if window[1]
              end
            end
          end
        end
      end
      SearchProResults.from_json(request(entry, payload)).search_results
    end

    def fetch(url : String) : FetchResult
      entry = endpoint(:fetch)
      payload = JSON.build do |json|
        json.object do
          json.field "url", url
        end
      end
      FetchResult.from_json(request(entry, payload))
    end

    def deepseek_search(query : String, count : Int32? = nil, need_content : Bool? = nil,
                        ori_question : String? = nil, localization : String? = nil) : Array(DeepSeekSearchResult)
      entry = endpoint(:deepseek_search)
      payload = JSON.build do |json|
        json.object do
          json.field "query", query
          json.field "count", count if count
          json.field "need_content", need_content unless need_content.nil?
          json.field "ori_question", ori_question if ori_question
          json.field "localization", localization if localization
        end
      end
      DeepSeekSearchResults.from_json(request(entry, payload)).results
    end

    def deepseek_fetch(url : String) : DeepSeekFetchResult
      entry = endpoint(:deepseek_fetch)
      payload = JSON.build do |json|
        json.object do
          json.field "url", url
        end
      end
      DeepSeekFetchResult.from_json(request(entry, payload))
    end

    def create_batch(input_file_id : String, completion_window : String,
                     metadata : Hash(String, String)? = nil) : Batch
      entry = endpoint(:create_batch)
      payload = JSON.build do |json|
        json.object do
          json.field "input_file_id", input_file_id
          json.field "endpoint", "/v1/chat/completions"
          json.field "completion_window", completion_window
          json.field "metadata", metadata if metadata
        end
      end
      Batch.from_json(request(entry, payload))
    end

    def list_batches(after : String? = nil, limit : Int32? = nil) : BatchList
      entry = endpoint(:list_batches)
      params = URI::Params.new
      params["after"] = after if after
      params["limit"] = limit.to_s if limit
      path = params.empty? ? entry.path : "#{entry.path}?#{params}"
      BatchList.from_json(request(entry, path: path))
    end

    def get_batch(batch_id : String) : Batch
      entry = endpoint(:get_batch)
      Batch.from_json(request(entry, path: "#{entry.path}/#{batch_id}"))
    end

    def cancel_batch(batch_id : String) : Batch
      entry = endpoint(:cancel_batch)
      Batch.from_json(request(entry, path: "#{entry.path}/#{batch_id}/cancel"))
    end

    private def endpoint(name : Symbol) : Endpoints::Entry
      Endpoints.for(@provider.id, name)
    end

    private def request(entry : Endpoints::Entry, body : String? = nil,
                        content_type : String = "application/json", path : String? = nil) : String
      headers = {} of String => String
      if model = @provider.models.first?
        headers = Identity.headers(model, @identity)
      end
      headers["Content-Type"] = content_type if body || entry.method == "POST"
      headers["Authorization"] = "Bearer #{@auth.auth.api_key}" if @auth.auth.api_key
      @auth.auth.headers.try &.each { |key, value| headers[key] = value }
      result = ""
      Http.request("#{@provider.base_url}#{path || entry.path}", entry.method, headers, body, @http_options, @abort) do |response|
        result = response.body_io.gets_to_end
      end
      result
    end

    private def estimate_message(json : JSON::Builder, role : String, content : String) : Nil
      json.object do
        json.field "role", role
        json.field "content", content
      end
    end

    private def estimate_message(json : JSON::Builder, message : Message) : Nil
      case message
      when SystemMessage
        text = Transcript.system_text(message)
        estimate_message(json, "system", text) unless text.empty?
      when UserMessage
        case content = message.content
        when String
          estimate_message(json, "user", content)
        else
          text = content.select(TextContent).map(&.text).join("\n")
          estimate_message(json, "user", text)
        end
      when AssistantMessage
        text = message.content.select(TextContent).map(&.text).join("")
        estimate_message(json, "assistant", text)
      when ToolResultMessage
        text = message.content.select(TextContent).map(&.text).join("\n")
        estimate_message(json, "tool", text)
      end
    end
  end
end
