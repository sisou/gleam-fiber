import birdie
import gleam/json
import gleam/option
import gleam/string
import gleeunit/should
import json_rpc/message

pub fn encoded_error_test() {
  message.StringId("id string")
  |> option.Some
  |> message.ErrorResponse(error: message.ErrorData(
    code: 404,
    message: "Not Found",
    data: option.None,
  ))
  |> message.encode
  |> birdie.snap(title: "encoded error")
}

pub fn encoded_error_data_test() {
  message.StringId("id string")
  |> option.Some
  |> message.ErrorResponse(error: message.ErrorData(
    code: -32_700,
    message: "Parse error",
    data: json.string("Unexpected End of Input") |> option.Some,
  ))
  |> message.encode
  |> birdie.snap(title: "encoded error with data")
}

pub fn encoded_notification_test() {
  message.Notification(method: "heartbeat", params: option.None)
  |> message.encode
  |> birdie.snap(title: "encoded notification")
}

pub fn encoded_notification_params_test() {
  message.Notification(
    method: "progress",
    params: json.object([#("complete", json.float(0.5))]) |> option.Some,
  )
  |> message.encode
  |> birdie.snap(title: "encoded notification with params")
}

pub fn encoded_request_test() {
  message.IntId(777_777)
  |> message.Request(method: "ping", params: option.None)
  |> message.encode
  |> birdie.snap(title: "encoded request")
}

pub fn encoded_request_params_test() {
  message.IntId(999_999)
  |> message.Request(
    method: "get",
    params: json.object([#("path", json.string("/posts"))]) |> option.Some,
  )
  |> message.encode
  |> birdie.snap(title: "encoded request with params")
}

pub fn encoded_response_test() {
  message.IntId(777_777)
  |> message.SuccessResponse(result: json.string("pong"))
  |> message.encode
  |> birdie.snap(title: "encoded response")
}

pub fn parse_notification_test() {
  "{\"jsonrpc\":\"2.0\",\"method\":\"heartbeat\"}"
  |> message.decode
  |> should.be_ok
  |> string.inspect
  |> birdie.snap(title: "parsed notification")
}

pub fn parse_notification_params_test() {
  "{\"jsonrpc\":\"2.0\",\"method\":\"progress\",\"params\":{\"complete\":0.5}}"
  |> message.decode
  |> should.be_ok
  |> string.inspect
  |> birdie.snap(title: "parsed notification with params")
}

pub fn parse_request_test() {
  "{\"jsonrpc\":\"2.0\",\"id\":777777,\"method\":\"ping\"}"
  |> message.decode
  |> should.be_ok
  |> string.inspect
  |> birdie.snap(title: "parsed request")
}

pub fn parse_request_params_test() {
  "{\"jsonrpc\":\"2.0\",\"id\":999999,\"method\":\"get\",\"params\":{\"path\":\"/posts\"}}"
  |> message.decode
  |> should.be_ok
  |> string.inspect
  |> birdie.snap(title: "parsed request with params")
}

pub fn parse_error_test() {
  "{\"jsonrpc\":\"2.0\",\"id\":\"id string\",\"error\":{\"code\":404,\"message\":\"Not Found\"}}"
  |> message.decode
  |> should.be_ok
  |> string.inspect
  |> birdie.snap(title: "prased error")
}

pub fn parse_error_data_test() {
  "{\"jsonrpc\":\"2.0\",\"id\":\"id string\",\"error\":{\"code\":-32700,\"message\":\"Parse error\",\"data\":\"Unexpected End of Input\"}}"
  |> message.decode
  |> should.be_ok
  |> string.inspect
  |> birdie.snap(title: "parsed error with data")
}

pub fn parse_response_test() {
  "{\"jsonrpc\":\"2.0\",\"id\":777777,\"result\":\"pong\"}"
  |> message.decode
  |> should.be_ok
  |> string.inspect
  |> birdie.snap(title: "parsed response")
}

pub fn invalid_message_test() {
  "{\"nonsense\":\"data\"}"
  |> message.decode
  |> should.be_error
  |> message.encode
  |> birdie.snap(title: "invalid request error message")
}

pub fn unexpected_byte_test() {
  "⭐"
  |> message.decode
  |> should.be_error
  |> message.encode
  |> birdie.snap(title: "unexpected byte error message")
}

pub fn unexpected_end_of_input_test() {
  "{\"method\": \"heartbe--"
  |> message.decode
  |> should.be_error
  |> message.encode
  |> birdie.snap(title: "unexpected end of input error message")
}

pub fn unexpected_sequence_test() {
  "\"\\uxxxx\""
  |> message.decode
  |> should.be_error
  |> message.encode
  |> birdie.snap(title: "unexpected sequence error message")
}
