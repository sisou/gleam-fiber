import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/function
import gleam/io
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/set
import gleam/string

import fiber/message
import fiber/response

type RequestCallback =
  fn(Option(Dynamic)) -> Result(Json, response.Error)

type NotificationCallback =
  fn(Option(Dynamic)) -> Nil

type SendFunction(send_conn, send_return, send_error) =
  fn(send_conn, String) -> Result(send_return, send_error)

pub type FiberBuilder {
  FiberBuilder(
    methods: Dict(String, RequestCallback),
    notifications: Dict(String, NotificationCallback),
  )
}

pub opaque type FiberState(send_conn, send_return, send_error) {
  FiberState(
    send: SendFunction(send_conn, send_return, send_error),
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

pub type Message {
  Request(
    method: String,
    params: Option(Json),
    id: message.Id,
    reply_subject: process.Subject(Result(Dynamic, message.ErrorData(Dynamic))),
  )
  Notification(method: String, params: Option(Json))
  Batch(
    requests: List(#(String, Option(Json), Option(message.Id))),
    ids: set.Set(message.Id),
    reply_subject: process.Subject(
      Dict(message.Id, Result(Dynamic, message.ErrorData(Dynamic))),
    ),
  )
  RemoveWaiting(id: message.Id)
  RemoveWaitingBatch(ids: set.Set(message.Id))
  Close
}

pub type Fiber =
  process.Subject(Message)

pub fn build_state(
  builder: FiberBuilder,
  send send: SendFunction(send_conn, send_return, send_error),
) -> FiberState(send_conn, send_return, send_error) {
  FiberState(
    send:,
    methods: builder.methods,
    notifications: builder.notifications,
    waiting: dict.new(),
    waiting_batches: dict.new(),
  )
}

pub fn wrap(
  establish: fn(fn() -> process.Selector(Message)) -> Result(anything, error),
) -> Result(Fiber, error) {
  let send_back = process.new_subject()

  let bind_selector = fn() {
    let subject = process.new_subject()

    process.send(send_back, subject)

    process.new_selector()
    |> process.selecting(subject, function.identity)
  }

  use _ <- result.map(establish(bind_selector))

  process.new_selector()
  |> process.selecting(send_back, function.identity)
  |> process.select_forever
}

fn stop_on_error(result: Result(a, b), state: d) -> actor.Next(c, d) {
  case result {
    Error(_) -> actor.Stop(process.Abnormal("Socket Closed"))
    Ok(_) -> actor.continue(state)
  }
}

fn add_waiting(
  connection: FiberState(a, b, c),
  id: message.Id,
  reply: process.Subject(Result(Dynamic, message.ErrorData(Dynamic))),
) -> FiberState(a, b, c) {
  FiberState(
    ..connection,
    waiting: connection.waiting |> dict.insert(id, reply),
  )
}

fn add_waiting_batch(
  connection: FiberState(a, b, c),
  ids: set.Set(message.Id),
  reply: process.Subject(
    Dict(message.Id, Result(Dynamic, message.ErrorData(Dynamic))),
  ),
) -> FiberState(a, b, c) {
  FiberState(
    ..connection,
    waiting_batches: connection.waiting_batches |> dict.insert(ids, reply),
  )
}

fn remove_waiting(
  connection: FiberState(a, b, c),
  id: message.Id,
) -> FiberState(a, b, c) {
  FiberState(..connection, waiting: connection.waiting |> dict.delete(id))
}

fn remove_waiting_batch(
  connection: FiberState(a, b, c),
  ids: set.Set(message.Id),
) -> FiberState(a, b, c) {
  FiberState(
    ..connection,
    waiting_batches: connection.waiting_batches |> dict.delete(ids),
  )
}

pub fn handle_text(
  state: FiberState(a, b, c),
  conn: a,
  message text: String,
) -> actor.Next(m, FiberState(a, b, c)) {
  case message.decode(text) {
    Error(error) -> {
      case error {
        json.UnexpectedFormat(_) ->
          message.ErrorData(
            code: -32_600,
            message: "Invalid Request",
            data: option.None,
          )
        json.UnexpectedByte(byte) ->
          message.ErrorData(
            code: -32_700,
            message: "Parse error",
            data: option.Some(json.string("Unexpected Byte: \"" <> byte <> "\"")),
          )

        json.UnexpectedEndOfInput ->
          message.ErrorData(
            code: -32_700,
            message: "Parse error",
            data: option.Some(json.string("Unexpected End of Input")),
          )
        json.UnexpectedSequence(sequence) ->
          message.ErrorData(
            code: -32_700,
            message: "Parse error",
            data: option.Some(json.string(
              "Unexpected Sequence: \"" <> sequence <> "\"",
            )),
          )
      }
      |> message.ErrorMessage
      |> message.encode
      |> json.to_string
      |> state.send(conn, _)
      |> stop_on_error(state)
    }
    Ok(message) -> handle_message(state, conn, message)
  }
}

pub fn fiber_message(
  state: FiberState(a, b, c),
  conn: a,
  message state_message: Message,
) -> actor.Next(m, FiberState(a, b, c)) {
  case state_message {
    Request(method, params, id, reply_subject) -> {
      message.Request(params, method, id)
      |> message.RequestMessage
      |> message.encode
      |> json.to_string
      |> state.send(conn, _)
      |> stop_on_error(state |> add_waiting(id, reply_subject))
    }
    Notification(method, params) -> {
      message.Notification(params, method)
      |> message.RequestMessage
      |> message.encode
      |> json.to_string
      |> state.send(conn, _)
      |> stop_on_error(state)
    }
    Batch(batch, ids, reply_subject) -> {
      batch
      |> list.map(fn(request) {
        let #(method, params, id) = request
        case id {
          option.None -> message.Notification(params, method)
          option.Some(id) -> message.Request(params, method, id)
        }
      })
      |> message.BatchRequestMessage
      |> message.encode
      |> json.to_string
      |> state.send(conn, _)
      |> stop_on_error(state |> add_waiting_batch(ids, reply_subject))
    }
    RemoveWaiting(id) -> actor.continue(state |> remove_waiting(id))
    RemoveWaitingBatch(ids) ->
      actor.continue(state |> remove_waiting_batch(ids))
    Close -> actor.Stop(process.Normal)
  }
}

pub fn handle_binary(
  state: FiberState(a, b, c),
  conn: a,
  message _binary: BitArray,
) -> actor.Next(m, FiberState(a, b, c)) {
  message.ErrorData(
    code: -32_700,
    message: "Parse error",
    data: option.Some(json.string("binary frames are unsupported")),
  )
  |> message.ErrorMessage
  |> message.encode
  |> json.to_string
  |> state.send(conn, _)
  |> stop_on_error(state)
}

fn handle_request_callback_result(
  result: Result(Json, response.Error),
  id: message.Id,
) -> message.Response(Json) {
  case result {
    Error(response.InvalidParams) -> {
      option.None
      |> message.ErrorData(code: -32_602, message: "Invalid params")
      |> message.ErrorResponse(id:)
    }
    Error(response.InternalError) -> {
      option.None
      |> message.ErrorData(code: -32_603, message: "Internal error")
      |> message.ErrorResponse(id:)
    }
    Error(response.CustomError(error)) -> {
      error
      |> message.ErrorResponse(id:)
    }
    Ok(result) -> {
      result
      |> message.SuccessResponse(id:)
    }
  }
}

fn process_request(
  state: FiberState(a, b, c),
  request: message.Request(Dynamic),
) -> Result(message.Response(Json), Nil) {
  case request {
    message.Notification(params, method) ->
      case state.notifications |> dict.get(method) {
        Error(Nil) -> {
          // simply ignore  and log unknown notifications, as the spec says never to reply to them
          io.println_error(
            "Received notification we don't have a handler for: "
            <> method
            <> ", params: "
            <> string.inspect(params),
          )
          Error(Nil)
        }
        Ok(callback) -> {
          callback(params)
          Error(Nil)
        }
      }
    message.Request(params, method, id) ->
      case state.methods |> dict.get(method) {
        Error(Nil) -> {
          option.Some(json.string(method))
          |> message.ErrorData(code: -32_601, message: "Method not found")
          |> message.ErrorResponse(id:)
          |> Ok
        }
        Ok(callback) -> {
          callback(params)
          |> handle_request_callback_result(id)
          |> Ok
        }
      }
  }
}

fn handle_request(
  state: FiberState(a, b, c),
  conn: a,
  request: message.Request(Dynamic),
) -> actor.Next(m, FiberState(a, b, c)) {
  case process_request(state, request) {
    Error(Nil) -> actor.continue(state)
    Ok(response) ->
      response
      |> message.ResponseMessage
      |> message.encode
      |> json.to_string
      |> state.send(conn, _)
      |> stop_on_error(state)
  }
}

fn handle_response(
  state: FiberState(a, b, c),
  _conn: a,
  response: message.Response(Dynamic),
) -> actor.Next(m, FiberState(a, b, c)) {
  case response {
    message.ErrorResponse(error, id) ->
      case state.waiting |> dict.get(id) {
        Error(Nil) -> {
          // we can't reply to this, so just log an error
          io.println_error(
            "Received error for id that we were not waiting for (it possibly timed out): "
            <> string.inspect(id)
            <> ", error: "
            <> string.inspect(error),
          )

          actor.continue(state)
        }
        Ok(reply_subject) -> {
          reply_subject |> process.send(Error(error))

          actor.continue(state)
        }
      }
    message.SuccessResponse(result, id) ->
      case state.waiting |> dict.get(id) {
        Error(Nil) -> {
          // we can't reply to this, so just log an error
          io.println_error(
            "Received response for id that we were not waiting for (it possibly timed out): "
            <> string.inspect(id)
            <> ", result: "
            <> string.inspect(result),
          )

          actor.continue(state)
        }
        Ok(reply_subject) -> {
          reply_subject |> process.send(Ok(result))

          actor.continue(state)
        }
      }
  }
}

fn handle_batch_request(
  state: FiberState(a, b, c),
  conn: a,
  batch: List(message.Request(Dynamic)),
) -> actor.Next(m, FiberState(a, b, c)) {
  batch
  |> list.map(process_request(state, _))
  |> result.values
  |> message.BatchResponseMessage
  |> message.encode
  |> json.to_string
  |> state.send(conn, _)
  |> stop_on_error(state)
}

fn handle_batch_response(
  state: FiberState(a, b, c),
  _conn: a,
  batch: List(message.Response(Dynamic)),
) -> actor.Next(m, FiberState(a, b, c)) {
  let ids =
    batch
    |> list.map(fn(response) {
      case response {
        message.ErrorResponse(_, id) -> id
        message.SuccessResponse(_, id) -> id
      }
    })
    |> set.from_list

  case state.waiting_batches |> dict.get(ids) {
    Error(Nil) -> {
      // we can't reply to this, so just log an error
      io.println_error(
        "Received batch response for an id set that we were not waiting for (it possibly timed out): "
        <> string.inspect(ids),
      )

      actor.continue(state)
    }
    Ok(reply_subject) -> {
      batch
      |> list.map(fn(response) {
        case response {
          message.ErrorResponse(error, id) -> #(id, Error(error))
          message.SuccessResponse(result, id) -> #(id, Ok(result))
        }
      })
      |> dict.from_list
      |> process.send(reply_subject, _)

      actor.continue(state)
    }
  }
}

fn handle_message(
  state: FiberState(a, b, c),
  conn: a,
  message fiber_message: message.Message(Dynamic),
) -> actor.Next(m, FiberState(a, b, c)) {
  case fiber_message {
    message.BatchRequestMessage(batch) ->
      handle_batch_request(state, conn, batch)
    message.BatchResponseMessage(batch) ->
      handle_batch_response(state, conn, batch)
    message.RequestMessage(request) -> handle_request(state, conn, request)
    message.ResponseMessage(response) -> handle_response(state, conn, response)
    message.ErrorMessage(error) -> {
      // we can't reply to this according to the spec, so just log an error
      io.println_error(
        "Received error without id (usually indicates we sent malformed data): "
        <> string.inspect(error),
      )

      actor.continue(state)
    }
  }
}
