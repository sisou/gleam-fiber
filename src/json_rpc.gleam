import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/io
import gleam/json.{type Json}
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string
import youid/uuid

import json_rpc/message

fn stop_on_error(result: Result(a, b), state: d) -> actor.Next(c, d) {
  case result {
    Error(_) -> actor.Stop(process.Abnormal("Socket Closed"))
    Ok(_) -> actor.continue(state)
  }
}

pub fn handle_text(
  rpc rpc: RpcConnection(a),
  message text: String,
) -> actor.Next(RpcMessage, RpcConnection(a)) {
  case message.decode(text) {
    Error(error_to_send) -> {
      message.encode(error_to_send)
      |> rpc.send
      |> stop_on_error(rpc)
    }
    Ok(message) -> handle_message(rpc, message)
  }
}

pub fn handle_rpc_message(
  rpc rpc: RpcConnection(a),
  message rpc_message: RpcMessage,
) -> actor.Next(RpcMessage, RpcConnection(a)) {
  case rpc_message {
    RpcRequest(method, params, reply_subject) -> {
      let id = message.StringId(uuid.v4_string())

      message.Request(id, method, params)
      |> message.encode
      |> rpc.send
      |> stop_on_error(rpc |> add_waiting(id, reply_subject))
    }
    RpcNotification(method, params) -> {
      message.Notification(method, params)
      |> message.encode
      |> rpc.send
      |> stop_on_error(rpc)
    }
    Close -> actor.Stop(process.Normal)
  }
}

pub fn handle_binary(
  rpc rpc: RpcConnection(a),
  message _binary: BitArray,
) -> actor.Next(RpcMessage, RpcConnection(a)) {
  message.ErrorResponse(
    id: option.None,
    error: message.ErrorData(
      code: -32_700,
      message: "Parse error",
      data: option.Some(json.string("binary frames are unsupported")),
    ),
  )
  |> message.encode
  |> rpc.send
  |> stop_on_error(rpc)
}

fn handle_message(
  rpc rpc: RpcConnection(send_error),
  message json_rpc_message: message.Message(Dynamic),
) -> actor.Next(RpcMessage, RpcConnection(send_error)) {
  case json_rpc_message {
    message.ErrorResponse(id, error) -> {
      case id {
        option.None -> {
          // we can't reply to this, so just log an error
          io.println_error(
            "Received error without id (usually indicates we sent malformed data): "
            <> string.inspect(error),
          )
          actor.continue(rpc)
        }
        option.Some(id) -> {
          case rpc.waiting |> dict.get(id) {
            Error(Nil) -> {
              // we can't reply to this, so just log an error
              io.println_error(
                "Received error for id that we were not waiting for (it possibly timed out): "
                <> string.inspect(id)
                <> ", error: "
                <> string.inspect(error),
              )
              actor.continue(rpc)
            }
            Ok(reply_subject) -> {
              reply_subject |> process.send(Error(error))
              actor.continue(rpc |> remove_waiting(id))
            }
          }
        }
      }
    }
    message.SuccessResponse(id, result) -> {
      case rpc.waiting |> dict.get(id) {
        Error(Nil) -> {
          // we can't reply to this, so just log an error
          io.println_error(
            "Received response for id that we were not waiting for (it possibly timed out): "
            <> string.inspect(id)
            <> ", result: "
            <> string.inspect(result),
          )
          actor.continue(rpc)
        }
        Ok(reply_subject) -> {
          reply_subject |> process.send(Ok(result))
          actor.continue(rpc |> remove_waiting(id))
        }
      }
    }
    message.Notification(method, params) -> {
      case rpc.notifications |> dict.get(method) {
        Error(Nil) -> {
          // simply ignore  and log unknown notifications, as the spec says never to reply to them
          io.println_error(
            "Received notification we don't have a handler for: "
            <> method
            <> ", params: "
            <> string.inspect(params),
          )
          actor.continue(rpc)
        }
        Ok(callback) -> {
          callback(params)
          actor.continue(rpc)
        }
      }
    }
    message.Request(id, method, params) -> {
      case rpc.methods |> dict.get(method) {
        Error(Nil) -> {
          message.ErrorResponse(
            id: option.Some(id),
            error: message.ErrorData(
              code: -32_601,
              message: "Method not found",
              data: option.Some(json.string(method)),
            ),
          )
          |> message.encode
          |> rpc.send
          |> stop_on_error(rpc)
        }
        Ok(callback) -> {
          let result = callback(params)
          case result {
            Error(InvalidParams) -> {
              message.ErrorResponse(
                id: option.Some(id),
                error: message.ErrorData(
                  code: -32_602,
                  message: "Invalid params",
                  data: option.None,
                ),
              )
              |> message.encode
              |> rpc.send
              |> stop_on_error(rpc)
            }
            Error(InternalError) -> {
              message.ErrorResponse(
                id: option.Some(id),
                error: message.ErrorData(
                  code: -32_603,
                  message: "Internal error",
                  data: option.None,
                ),
              )
              |> message.encode
              |> rpc.send
              |> stop_on_error(rpc)
            }
            Error(CustomError(error)) -> {
              message.ErrorResponse(id: option.Some(id), error:)
              |> message.encode
              |> rpc.send
              |> stop_on_error(rpc)
            }
            Ok(result) -> {
              message.SuccessResponse(id:, result:)
              |> message.encode
              |> rpc.send
              |> stop_on_error(rpc)
            }
          }
        }
      }
    }
  }
}

pub type RpcError {
  InvalidParams
  InternalError
  CustomError(message.ErrorData(Json))
}

pub type RequestCallback =
  fn(Option(Dynamic)) -> Result(Json, RpcError)

pub type NotificationCallback =
  fn(Option(Dynamic)) -> Nil

pub type RpcReplySubject =
  process.Subject(Result(Dynamic, message.ErrorData(Dynamic)))

pub type RpcMessage {
  RpcRequest(
    method: String,
    params: option.Option(Json),
    reply_subject: RpcReplySubject,
  )
  RpcNotification(method: String, params: option.Option(Json))
  Close
}

pub type SendFunction(send_error) =
  fn(String) -> Result(Nil, send_error)

pub type RpcBuilder {
  RpcBuilder(
    methods: Dict(String, RequestCallback),
    notifications: Dict(String, NotificationCallback),
  )
}

pub fn new() {
  RpcBuilder(methods: dict.new(), notifications: dict.new())
}

pub fn add_method(
  builder builder: RpcBuilder,
  method method: String,
  callback callback: RequestCallback,
) -> RpcBuilder {
  RpcBuilder(
    ..builder,
    methods: builder.methods |> dict.insert(method, callback),
  )
}

pub fn on_notification(
  builder builder: RpcBuilder,
  method method: String,
  callback callback: NotificationCallback,
) -> RpcBuilder {
  RpcBuilder(
    ..builder,
    notifications: builder.notifications |> dict.insert(method, callback),
  )
}

pub fn bind(
  builder builder: RpcBuilder,
  send send: SendFunction(a),
) -> RpcConnection(a) {
  RpcConnection(
    send:,
    methods: builder.methods,
    notifications: builder.notifications,
    waiting: dict.new(),
  )
}

pub type RpcConnection(send_error) {
  RpcConnection(
    send: SendFunction(send_error),
    methods: Dict(String, RequestCallback),
    notifications: Dict(String, NotificationCallback),
    waiting: Dict(message.RpcId, RpcReplySubject),
  )
}

pub fn add_waiting(
  connection: RpcConnection(a),
  id: message.RpcId,
  reply: RpcReplySubject,
) -> RpcConnection(a) {
  RpcConnection(
    ..connection,
    waiting: connection.waiting |> dict.insert(id, reply),
  )
}

pub fn remove_waiting(
  connection: RpcConnection(a),
  id: message.RpcId,
) -> RpcConnection(a) {
  RpcConnection(..connection, waiting: connection.waiting |> dict.delete(id))
}

pub type RequestError {
  DecodeError(dynamic.DecodeErrors)
  ReturnedError(message.ErrorData(Dynamic))
}

pub type RequestBuilder(return) {
  RequestBuilder(
    method: String,
    params: Option(Json),
    decoder: dynamic.Decoder(return),
  )
}

pub fn request_builder(method method: String) {
  RequestBuilder(method:, params: option.None, decoder: dynamic.dynamic)
}

pub fn params(request: RequestBuilder(a), params: Json) {
  RequestBuilder(..request, params: option.Some(params))
}

pub fn decoder(
  request: RequestBuilder(a),
  decoder: dynamic.Decoder(b),
) -> RequestBuilder(b) {
  RequestBuilder(method: request.method, params: request.params, decoder:)
}

pub fn call(
  request: RequestBuilder(a),
  rpc rpc_subject: process.Subject(RpcMessage),
  timeout timeout: Int,
) -> Result(a, RequestError) {
  rpc_subject
  |> actor.call(RpcRequest(request.method, request.params, _), timeout)
  |> result.map(fn(data) {
    data
    |> request.decoder
    |> result.map_error(DecodeError)
  })
  |> result.map_error(ReturnedError)
  |> result.flatten
}

pub fn notify(
  request: RequestBuilder(Dynamic),
  rpc rpc_subject: process.Subject(RpcMessage),
) -> Nil {
  rpc_subject
  |> process.send(RpcNotification(request.method, request.params))
}

pub fn close(rpc rpc_subject: process.Subject(RpcMessage)) {
  rpc_subject
  |> process.send(Close)
}
