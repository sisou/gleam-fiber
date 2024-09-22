import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/option.{type Option}
import youid/uuid

import json_rpc/message

pub type Request(return) {
  Request(
    method: String,
    params: Option(Json),
    decoder: dynamic.Decoder(return),
    id: Option(message.Id),
  )
}

pub fn new(method method: String) -> Request(Dynamic) {
  Request(
    method:,
    params: option.None,
    decoder: dynamic.dynamic,
    id: option.None,
  )
}

pub fn with_params(request: Request(a), params: Json) -> Request(a) {
  Request(..request, params: option.Some(params))
}

pub fn with_decoder(
  request: Request(a),
  decoder decoder: dynamic.Decoder(b),
) -> Request(b) {
  Request(
    method: request.method,
    params: request.params,
    decoder:,
    id: request.id,
  )
}

pub fn with_string_id(request: Request(a), id id: String) -> Request(a) {
  Request(..request, id: option.Some(message.StringId(id)))
}

pub fn with_int_id(request: Request(a), id id: Int) -> Request(a) {
  Request(..request, id: option.Some(message.IntId(id)))
}

pub fn with_uuid(request: Request(a)) -> Request(a) {
  Request(..request, id: option.Some(uuid.v4_string() |> message.StringId))
}
