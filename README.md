# fiber

An implementation of the JSON-RPC 2.0 protocol in Gleam!

[![Package Version](https://img.shields.io/hexpm/v/fiber)](https://hex.pm/packages/fiber)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/fiber/)

```sh
gleam add fiber@1
```

Fiber aims to make working with JSON-RPC as ergonomic as possible. It provides
functions for encoding and decoding JSON-RPC messages, builders to define
requests and request handlers, and tools to construct an actor that keeps track
of request ids for you.

This package is not tied to any communication protocol. Instead, it's designed
for you to plug in a backend of your choice using some minimal boilerplate. This
is handled by `fiber/backend`, which contains everything you need to create your
own Fiber backend and nothing more. That way, you can keep your backend
implementation and RPC logic completely separate and composable. See
[Backend Example](#backend-example) below.

Further documentation can be found at <https://hexdocs.pm/fiber>.

> [!Note]
> This package is still a work in progress, and is not yet published.

## Client Example

```gleam
import gleam/dynamic/decode
import gleam/json
import gleeunit/should

import fiber
import fiber/request

fn start_client(fiber) {
  // Depends on your chosen communication protocol.
  // You might want to put it in another module.
  // See "Backend Example" below.
}

fn ping() {
  request.new(method: "ping")
  // We expect "pong" from this, so we can decode the result into a string.
  |> request.with_decoder(decode.string)
}

fn file_updated(file_name) {
  request.new(method: "fileUpdated")
  |> request.with_params(json.string(file_name))
}

pub fn main() {
  use fiber <- result.try(start_client(fiber.new()))

  // Requests are not called immediately, they must be passed to fiber.call.
  fiber.call(fiber, ping(), 500) |> should.equal(Ok("pong"))
}
```

## Server Example

```gleam
import gleam/erlang/process
import gleam/json
import gleam/result

import fiber
import fiber/response

fn start_server(fiber) {
  // Depends on your chosen communication protocol.
  // You might want to put it in another module.
  // See "Backend Example" below.
}

fn pong(_) {
  json.string("pong") |> Ok
}

pub fn main() {
  let assert Ok(_) = fiber.new()
  |> fiber.on_request("ping", pong)
  |> fiber.on_notification("fileUpdated", file_updated)
  |> start_server

  process.sleep_forever()
}
```

## Backend Example

This example uses [Mist](https://hexdocs.pm/mist/) to create a websocket server
that upgrades every request into a websocket connection. Fiber's `backend`
functions are used to easily plug in to Mist's websocket creation function.

```gleam


import fiber/backend


pub fn start_server(builder, port) {
  // This builder is generated by functions in the root fiber module.
  // We use the build_state function to transform it into a FiberState.
  // Fiber needs a way to send messages, so we pass it in here.
  // The passed send_text_frame function is used by other Fiber functions.
  let state = backend.build_state(builder, mist.send_text_frame)

  // backend.wrap is a convenience function that does the following:
  // - Passes the bind_selector function into the passed "establish" function
  // - Returns a Subject that can be used to send Fiber messages to the
  //   Selector returned by bind_selector
  // This makes it very easy to get a Subject that can be used by Fiber functions
  use bind_selector <- backend.wrap

  // This upgrades all incoming requests into websockets.
  // You likely want something more sophisticated for most cases.
  mist.new(mist.websocket(
    _,
    // The on_init function uses bind_selector, passed from backend.wrap.
    // This makes integration easy.
    on_init: fn(_) { #(state, option.Some(bind_selector())) },
    on_close: fn(_state) { Nil },
    handler: fn(state, conn, websocket_message) {
      // These three backend functions are easy to plug into case expressions.
      case websocket_message {
        mist.Text(text) -> backend.handle_text(state, conn, text)
        mist.Binary(binary) -> backend.handle_binary(state, conn, binary)
        mist.Custom(message) -> backend.fiber_message(state, conn, message)
        mist.Closed | mist.Shutdown -> actor.Stop(process.Normal)
      }
    },
  ))
  |> mist.port(port)
  |> mist.start_http
}
```
