import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/set
import youid/uuid

import json_rpc/message
import json_rpc/request

pub type RpcError {
  InvalidParams
  InternalError
  CustomError(message.ErrorData(Json))
}

type RequestCallback =
  fn(Option(Dynamic)) -> Result(Json, RpcError)

type NotificationCallback =
  fn(Option(Dynamic)) -> Nil

type SendFunction(conn, send_error) =
  fn(conn, String) -> Result(Nil, send_error)

pub type RpcConnection(conn, send_error) {
  RpcConnection(
    send: SendFunction(conn, send_error),
    methods: Dict(String, RequestCallback),
    notifications: Dict(String, NotificationCallback),
    waiting: Dict(
      message.Id,
      process.Subject(Result(Dynamic, message.ErrorData(Dynamic))),
    ),
    waiting_batches: Dict(
      set.Set(message.Id),
      process.Subject(
        Dict(message.Id, Result(Dynamic, message.ErrorData(Dynamic))),
      ),
    ),
  )
}

pub fn new(send send_function: SendFunction(a, b)) -> RpcConnection(a, b) {
  RpcConnection(
    methods: dict.new(),
    notifications: dict.new(),
    send: send_function,
    waiting: dict.new(),
    waiting_batches: dict.new(),
  )
}

pub fn on_request(
  builder builder: RpcConnection(a, b),
  method method: String,
  callback callback: RequestCallback,
) -> RpcConnection(a, b) {
  RpcConnection(
    ..builder,
    methods: builder.methods |> dict.insert(method, callback),
  )
}

pub fn on_notification(
  builder builder: RpcConnection(a, b),
  method method: String,
  callback callback: NotificationCallback,
) -> RpcConnection(a, b) {
  RpcConnection(
    ..builder,
    notifications: builder.notifications |> dict.insert(method, callback),
  )
}

pub type RpcMessage {
  RpcRequest(
    method: String,
    params: Option(Json),
    id: message.Id,
    reply_subject: process.Subject(Result(Dynamic, message.ErrorData(Dynamic))),
  )
  RpcNotification(method: String, params: Option(Json))
  RpcBatch(
    requests: List(#(String, Option(Json), Option(message.Id))),
    ids: set.Set(message.Id),
    reply_subject: process.Subject(
      Dict(message.Id, Result(Dynamic, message.ErrorData(Dynamic))),
    ),
  )
  RpcRemoveWaiting(id: message.Id)
  RpcRemoveWaitingBatch(ids: set.Set(message.Id))
  Close
}

pub type RequestError(a) {
  ReturnedError(message.ErrorData(Dynamic))
  DecodeError(dynamic.DecodeErrors)
  CallError(process.CallError(a))
}

pub fn call(
  rpc_subject: process.Subject(RpcMessage),
  request: request.Request(a),
  timeout timeout: Int,
) -> Result(a, RequestError(Result(Dynamic, message.ErrorData(Dynamic)))) {
  let id = request.id |> option.unwrap(message.StringId(uuid.v4_string()))

  let return =
    rpc_subject
    |> process.try_call(
      RpcRequest(request.method, request.params, id, _),
      timeout,
    )
    |> result.map_error(CallError)
    |> result.map(fn(call_result) {
      call_result
      |> result.map(fn(data) {
        request.decoder(data)
        |> result.map_error(DecodeError)
      })
      |> result.map_error(ReturnedError)
      |> result.flatten
    })
    |> result.flatten

  rpc_subject |> process.send(RpcRemoveWaiting(id))

  return
}

pub fn notify(
  rpc_subject: process.Subject(RpcMessage),
  request: request.Request(Dynamic),
) -> Nil {
  rpc_subject
  |> process.send(RpcNotification(request.method, request.params))
}

pub fn call_batch(
  rpc_subject: process.Subject(RpcMessage),
  requests: List(request.Request(a)),
  timeout timeout: Int,
) {
  let ids =
    requests
    |> list.filter_map(fn(request) {
      case request.id {
        option.None -> Error(Nil)
        option.Some(id) -> Ok(id)
      }
    })
    |> set.from_list

  let batch =
    requests
    |> list.map(fn(request) { #(request.method, request.params, request.id) })

  let return =
    rpc_subject
    |> process.try_call(RpcBatch(batch, ids, _), timeout)
    |> result.map_error(CallError)

  rpc_subject |> process.send(RpcRemoveWaitingBatch(ids))

  return
}

pub fn close(rpc_subject: process.Subject(RpcMessage)) {
  rpc_subject
  |> process.send(Close)
}
