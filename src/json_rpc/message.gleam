import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result

pub type RpcId {
  IntId(Int)
  StringId(String)
}

pub type ErrorData(dyn) {
  ErrorData(code: Int, message: String, data: Option(dyn))
  ErrorString(String)
}

pub type Message(dyn) {
  Notification(method: String, params: Option(dyn))
  Request(id: RpcId, method: String, params: Option(dyn))
  SuccessResponse(id: RpcId, result: dyn)
  ErrorResponse(id: Option(RpcId), error: ErrorData(dyn))
}

fn id_decoder() {
  dynamic.any([
    fn(data) { dynamic.int(data) |> result.map(IntId) },
    fn(data) { dynamic.string(data) |> result.map(StringId) },
  ])
}

fn error_decoder() {
  dynamic.any([
    fn(v) { dynamic.string(v) |> result.map(ErrorString) },
    dynamic.decode3(
      ErrorData,
      dynamic.field("code", dynamic.int),
      dynamic.field("message", dynamic.string),
      dynamic.optional_field("data", dynamic.dynamic),
    ),
  ])
}

fn notification_decoder() {
  dynamic.decode2(
    Notification,
    dynamic.field("method", dynamic.string),
    dynamic.optional_field("params", dynamic.dynamic),
  )
}

fn request_decoder() {
  dynamic.decode3(
    Request,
    dynamic.field("id", id_decoder()),
    dynamic.field("method", dynamic.string),
    dynamic.optional_field("params", dynamic.dynamic),
  )
}

fn success_response_decoder() {
  dynamic.decode2(
    SuccessResponse,
    dynamic.field("id", id_decoder()),
    dynamic.field("result", dynamic.dynamic),
  )
}

fn error_response_decoder() {
  dynamic.decode2(
    ErrorResponse,
    dynamic.field("id", dynamic.optional(id_decoder())),
    dynamic.field("error", error_decoder()),
  )
}

fn parse_or_format_error_message(error) {
  case error {
    json.UnexpectedFormat(_) ->
      ErrorResponse(
        error: ErrorData(code: -32_600, message: "Invalid Request", data: None),
        id: None,
      )
    json.UnexpectedByte(byte) ->
      ErrorResponse(
        error: ErrorData(
          code: -32_700,
          message: "Parse error",
          data: Some(json.string("Unexpected Byte: \"" <> byte <> "\"")),
        ),
        id: None,
      )
    json.UnexpectedEndOfInput ->
      ErrorResponse(
        error: ErrorData(
          code: -32_700,
          message: "Parse error",
          data: Some(json.string("Unexpected End of Input")),
        ),
        id: None,
      )
    json.UnexpectedSequence(sequence) ->
      ErrorResponse(
        error: ErrorData(
          code: -32_700,
          message: "Parse error",
          data: Some(json.string("Unexpected Sequence: \"" <> sequence <> "\"")),
        ),
        id: None,
      )
  }
}

pub fn decode(text: String) -> Result(Message(Dynamic), Message(Json)) {
  let message_decoder =
    dynamic.any([
      request_decoder(),
      notification_decoder(),
      success_response_decoder(),
      error_response_decoder(),
    ])

  json.decode(text, message_decoder)
  |> result.map_error(parse_or_format_error_message)
}

fn encode_id(id: RpcId) {
  case id {
    IntId(i) -> json.int(i)
    StringId(s) -> json.string(s)
  }
}

pub fn encode(message: Message(Json)) -> String {
  case message {
    Notification(method, params) ->
      json.object(
        result.values([
          #("jsonrpc", json.string("2.0")) |> Ok,
          #("method", json.string(method)) |> Ok,
          option.map(params, pair.new("params", _)) |> option.to_result(Nil),
        ]),
      )
    Request(id, method, params) ->
      json.object(
        result.values([
          #("jsonrpc", json.string("2.0")) |> Ok,
          #("id", encode_id(id)) |> Ok,
          #("method", json.string(method)) |> Ok,
          params |> option.map(pair.new("params", _)) |> option.to_result(Nil),
        ]),
      )
    SuccessResponse(id, result) ->
      json.object([
        #("jsonrpc", json.string("2.0")),
        #("id", encode_id(id)),
        #("result", result),
      ])
    ErrorResponse(id, error) ->
      json.object([
        #("jsonrpc", json.string("2.0")),
        #("id", json.nullable(id, encode_id)),
        #("error", case error {
          ErrorData(code, message, data) ->
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
        }),
      ])
  }
  |> json.to_string
}
