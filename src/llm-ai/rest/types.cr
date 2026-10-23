# src/llm-ai/rest/types.cr
require "json"

module LLM::AI::Rest
  struct Balance
    include JSON::Serializable

    getter code : Int32
    getter data : BalanceData
    getter scode : String
    getter status : Bool
  end

  struct BalanceData
    include JSON::Serializable

    getter available_balance : Float64
    getter voucher_balance : Float64
    getter cash_balance : Float64
  end

  struct RemoteModel
    include JSON::Serializable

    getter id : String
    getter object : String?
    getter created : Int64?
    getter owned_by : String?
    getter context_length : Int32?
    getter supports_image_in : Bool?
    getter supports_video_in : Bool?
    getter supports_reasoning : Bool?
  end

  struct RemoteModelList
    include JSON::Serializable

    getter object : String
    getter data : Array(RemoteModel)
  end

  struct FileObject
    include JSON::Serializable

    getter id : String
    getter object : String
    getter bytes : Int64
    getter created_at : Int64
    getter filename : String
    getter purpose : String
    getter status : String?
    getter status_details : String?
    getter expires_at : Int64?
  end

  struct FileList
    include JSON::Serializable

    getter object : String
    getter data : Array(FileObject)
  end

  struct FileDelete
    include JSON::Serializable

    getter id : String
    getter object : String
    getter deleted : Bool
  end

  struct TokenEstimate
    include JSON::Serializable

    getter data : TokenEstimateData

    def total_tokens : Int32
      data.total_tokens
    end
  end

  struct TokenEstimateData
    include JSON::Serializable

    getter total_tokens : Int32
  end

  struct SignatureVerification
    include JSON::Serializable

    getter valid : Bool
  end

  struct SearchResult
    include JSON::Serializable

    getter authority : String
    getter date : String
    getter icon : String
    getter mime : String
    getter site_name : String
    getter snippet : String
    getter text : String
    getter title : String
    getter url : String
  end

  struct SearchResults
    include JSON::Serializable

    getter search_results : Array(SearchResult)
  end

  struct SearchProChunk
    include JSON::Serializable

    getter text : String
    getter score : Float64
  end

  struct SearchProResult
    include JSON::Serializable

    getter authority : String
    getter date : String
    getter icon : String
    getter mime : String
    getter site_name : String
    getter snippet : String
    getter title : String
    getter url : String
    getter chunks : Array(SearchProChunk)
  end

  struct SearchProResults
    include JSON::Serializable

    getter search_results : Array(SearchProResult)
  end

  struct FetchResult
    include JSON::Serializable

    getter url : String
    getter markdown : String
    getter title : String
  end

  struct BatchRequestCounts
    include JSON::Serializable

    getter completed : Int32
    getter failed : Int32
    getter total : Int32
  end

  struct Batch
    include JSON::Serializable

    getter id : String
    getter object : String
    getter endpoint : String
    getter input_file_id : String
    getter completion_window : String
    getter status : String
    getter output_file_id : String?
    getter error_file_id : String?
    getter created_at : Int64
    getter in_progress_at : Int64?
    getter expires_at : Int64?
    getter finalizing_at : Int64?
    getter completed_at : Int64?
    getter failed_at : Int64?
    getter cancelling_at : Int64?
    getter cancelled_at : Int64?
    getter request_counts : BatchRequestCounts
    getter metadata : Hash(String, String)?
  end

  struct BatchList
    include JSON::Serializable

    getter object : String
    getter data : Array(Batch)
    getter has_more : Bool?
  end
end
