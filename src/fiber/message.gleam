import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/pair
import gleam/result

pub type Id {
  IntId(Int)
  StringId(String)
}

pub type ErrorData(dyn) {
  ErrorData(data: Option(dyn), code: Int, message: String)
  /// This breaks specification, but some implementations do it anyways. It's
  /// better to handle it than to cause decode errors, especially since such
  /// errors are likely not recoverable like structured ones would be.
  ErrorString(String)
}

pub type Request(dyn) {
  Request(params: Option(dyn), method: String, id: Id)
  Notification(params: Option(dyn), method: String)
}

pub type Response(dyn) {
  SuccessResponse(result: dyn, id: Id)
  ErrorResponse(error: ErrorData(dyn), id: Id)
}

pub type Message(dyn) {
  RequestMessage(Request(dyn))
  ResponseMessage(Response(dyn))
  ErrorMessage(ErrorData(dyn))
  BatchRequestMessage(List(Request(dyn)))
  BatchResponseMessage(List(Response(dyn)))
}

fn id_decoder() {
  dynamic.any([
    fn(data) { dynamic.int(data) |> result.map(IntId) },
    fn(data) { dynamic.string(data) |> result.map(StringId) },
  ])
}

fn error_data_decoder() {
  dynamic.any([
    fn(v) { dynamic.string(v) |> result.map(ErrorString) },
    dynamic.decode3(
      ErrorData,
      dynamic.optional_field("data", dynamic.dynamic),
      dynamic.field("code", dynamic.int),
      dynamic.field("message", dynamic.string),
    ),
  ])
}

fn request_decoder() {
  dynamic.any([
    dynamic.decode3(
      Request,
      dynamic.optional_field("params", dynamic.dynamic),
      dynamic.field("method", dynamic.string),
      dynamic.field("id", id_decoder()),
    ),
    dynamic.decode2(
      Notification,
      dynamic.optional_field("params", dynamic.dynamic),
      dynamic.field("method", dynamic.string),
    ),
  ])
}

fn response_decoder() {
  dynamic.any([
    dynamic.decode2(
      SuccessResponse,
      dynamic.field("result", dynamic.dynamic),
      dynamic.field("id", id_decoder()),
    ),
    dynamic.decode2(
      ErrorResponse,
      dynamic.field("error", error_data_decoder()),
      dynamic.field("id", id_decoder()),
    ),
  ])
}

fn error_decoder() {
  dynamic.field("error", error_data_decoder())
}

fn message_decoder() {
  dynamic.any([
    fn(d) {
      response_decoder()(d)
      |> result.map(ResponseMessage)
    },
    fn(d) {
      request_decoder()(d)
      |> result.map(RequestMessage)
    },
    fn(d) {
      error_decoder()(d)
      |> result.map(ErrorMessage)
    },
    fn(d) {
      dynamic.list(request_decoder())(d)
      |> result.map(BatchRequestMessage)
    },
    fn(d) {
      dynamic.list(response_decoder())(d)
      |> result.map(BatchResponseMessage)
    },
  ])
}

pub fn decode(text: String) -> Result(Message(Dynamic), json.DecodeError) {
  json.decode(text, message_decoder())
}

pub fn from_json(text: String) -> Result(Message(Dynamic), json.DecodeError) {
  decode(text)
}

fn encode_id(id: Id) {
  case id {
    IntId(i) -> json.int(i)
    StringId(s) -> json.string(s)
  }
}

fn encode_error_data(error: ErrorData(Json)) {
  case error {
    ErrorData(data, code, message) ->
      json.object(
        result.values([
          #("code", json.int(code)) |> Ok,
          #("message", json.string(message)) |> Ok,
          data
            |> option.map(pair.new("data", _))
            |> option.to_result(Nil),
        ]),
      )
    ErrorString(s) -> json.string(s)
  }
}

fn encode_request(request: Request(Json)) {
  case request {
    Notification(params, method) ->
      json.object(
        result.values([
          #("jsonrpc", json.string("2.0")) |> Ok,
          #("method", json.string(method)) |> Ok,
          option.map(params, pair.new("params", _)) |> option.to_result(Nil),
        ]),
      )
    Request(params, method, id) ->
      json.object(
        result.values([
          #("jsonrpc", json.string("2.0")) |> Ok,
          #("id", encode_id(id)) |> Ok,
          #("method", json.string(method)) |> Ok,
          params |> option.map(pair.new("params", _)) |> option.to_result(Nil),
        ]),
      )
  }
}

fn encode_response(response: Response(Json)) {
  case response {
    ErrorResponse(error, id) ->
      json.object([
        #("jsonrpc", json.string("2.0")),
        #("id", encode_id(id)),
        #("error", encode_error_data(error)),
      ])
    SuccessResponse(result, id) ->
      json.object([
        #("jsonrpc", json.string("2.0")),
        #("id", encode_id(id)),
        #("result", result),
      ])
  }
}

fn encode_error(error: ErrorData(Json)) {
  json.object([
    #("jsonrpc", json.string("2.0")),
    #("id", json.null()),
    #("error", encode_error_data(error)),
  ])
}

pub fn encode(message: Message(Json)) -> Json {
  case message {
    BatchRequestMessage(batch) -> batch |> json.array(encode_request)
    BatchResponseMessage(batch) -> batch |> json.array(encode_response)
    ErrorMessage(error) -> encode_error(error)
    RequestMessage(request) -> encode_request(request)
    ResponseMessage(response) -> encode_response(response)
  }
}

pub fn to_json(message: Message(Json)) -> Json {
  encode(message)
}
