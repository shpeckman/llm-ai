# src/llm-ai/rest/endpoints.cr
module LLM::AI::Rest
  module Endpoints
    record Entry, method : String, path : String

    MOONSHOT = {
      list_models:      Entry.new("GET", "/v1/models"),
      balance:          Entry.new("GET", "/v1/users/me/balance"),
      upload_file:      Entry.new("POST", "/v1/files"),
      list_files:       Entry.new("GET", "/v1/files"),
      get_file:         Entry.new("GET", "/v1/files"),
      delete_file:      Entry.new("DELETE", "/v1/files"),
      file_content:     Entry.new("GET", "/v1/files"),
      estimate_tokens:  Entry.new("POST", "/v1/tokenizers/estimate-token-count"),
      verify_signature: Entry.new("POST", "/v1/signatures/verify"),
      web_search:       Entry.new("POST", "/v1/tools/search"),
      web_search_pro:   Entry.new("POST", "/v1/tools/search_pro"),
      fetch:            Entry.new("POST", "/v1/tools/fetch"),
      create_batch:     Entry.new("POST", "/v1/batches"),
      list_batches:     Entry.new("GET", "/v1/batches"),
      get_batch:        Entry.new("GET", "/v1/batches"),
      cancel_batch:     Entry.new("POST", "/v1/batches"),
    }

    DEEPSEEK = {
      deepseek_search: Entry.new("POST", "/v1/tools/search"),
      deepseek_fetch:  Entry.new("POST", "/v1/tools/fetch"),
      upload_file:     Entry.new("POST", "/files"),
      list_files:      Entry.new("GET", "/files"),
      get_file:        Entry.new("GET", "/files"),
      delete_file:     Entry.new("DELETE", "/files"),
    }

    TABLES = {
      "moonshot" => MOONSHOT,
      "deepseek" => DEEPSEEK,
    }

    def self.for(provider_id : String, endpoint : Symbol) : Entry
      table = TABLES[provider_id]? ||
              raise ModelsError.new("capability", "Provider #{provider_id} has no REST endpoints")
      table[endpoint]? ||
        raise ModelsError.new("capability", "Provider #{provider_id} does not support #{endpoint}")
    end
  end
end
