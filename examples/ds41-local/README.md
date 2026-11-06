# DS4.1 local same-checkpoint smoke bench

Compare one quantized abliterated DeepSeek V4.1 GGUF, direct against runtime leCore, on the machine that already holds the file. This bench does not contain weights, does not name a hosted model, and does not call a completion by itself.

The checkpoint the router must identify:

| | |
| --- | --- |
| bytes | `103425694816` |
| sha256 | `e8289c0026d746197d5f9b865b0b87c4a16dc94430d9cfed4a11074bf05ea36e` |

Earlier measurements on the Asus V15 resident server (plain DSML `12/24` in `2.348s`, leCore `20/24` in `7.511s`, weighted path `0.029s`) are prior notes. Nothing in this repository re-ran that inference. The resident server was stopped, and a cloud agent cannot reach it.

## What you set locally

There is no default base URL. The model ids `direct` and `lecore` are the names the local wrapper must list; change them in `bench.yml` only together with that wrapper.

```sh
export LEMANS_LOCAL_API_BASE=http://127.0.0.1:8080/v1   # your router, loopback or LAN
export LEMANS_LOCAL_API_KEY=local-dummy                 # placeholder only; never a real token
```

`LEMANS_LOCAL_API_BASE` is the integration URL. Identity is `GET $LEMANS_LOCAL_API_BASE/models`. Completions go to `$LEMANS_LOCAL_API_BASE/chat/completions`. Allowed hosts are loopback, private and link-local addresses, single-label LAN names, and names ending in `.local`, `.lan`, or `.internal`. A public or hosted API host is rejected before any socket is opened.

The bench file already carries the checkpoint. These two variables are only needed when you drive `miniswen` without the bench:

```sh
export LEMANS_LOCAL_CHECKPOINT_SHA256=e8289c0026d746197d5f9b865b0b87c4a16dc94430d9cfed4a11074bf05ea36e
export LEMANS_LOCAL_CHECKPOINT_BYTES=103425694816
```

The harness-side `miniswen` agent keeps the router call on the host. The sandbox network is `none`, so the model shell does not inherit `LEMANS_LOCAL_API_KEY` or any other `*_KEY` / `*_TOKEN` / `*_SECRET` / `*_JWT` variable. `miniswen-installed` receives only `LEMANS_LOCAL_API_BASE`, the dummy key, and the checkpoint figures, and only if you put the router host on the allowlist.

## Model list

Both arms must appear in one list, with the same bytes and digest, and `checkpoint.arm` equal to the model id:

```json
{
  "object": "list",
  "data": [
    {
      "id": "direct",
      "checkpoint": {
        "sha256": "e8289c0026d746197d5f9b865b0b87c4a16dc94430d9cfed4a11074bf05ea36e",
        "bytes": 103425694816,
        "arm": "direct"
      }
    },
    {
      "id": "lecore",
      "checkpoint": {
        "sha256": "e8289c0026d746197d5f9b865b0b87c4a16dc94430d9cfed4a11074bf05ea36e",
        "bytes": 103425694816,
        "arm": "lecore"
      }
    }
  ]
}
```

A missing id, a missing checkpoint, or a mismatched digest raises before a completion. Nothing is substituted.

## Usage hook

Standard `usage` counts are recorded. Prompt, completion, and reasoning tokens that the body does not report stay unknown (`null`), not zero. Each HTTP completion counts as one request. Wall time is measured around that call.

The wrapper may add a `lemans` object (or `lecore` when `lemans` is absent) when the visible usage undercounts chain-of-thought or internal forwards:

```json
{
  "usage": {
    "prompt_tokens": 100,
    "completion_tokens": 20,
    "completion_tokens_details": { "reasoning_tokens": 15 }
  },
  "lemans": {
    "requests": 4,
    "prompt_tokens": 100,
    "completion_tokens": 20,
    "reasoning_tokens": 15,
    "generated_tokens": 35,
    "cost_usd": 0,
    "phases": [{ "name": "weighted", "duration": 0.029, "tokens": 8 }]
  }
}
```

`generated_tokens`, when present, is the full generation and replaces the visible completion total. `requests` / `model_requests` is the server's own call count; if the key is absent the trial stores `model_requests: null` and still records the one HTTP call. `phases` are copied only from this object. A local run with no reported price stays `$0.00` (`local_provider`). A reported `cost` or `cost_usd` is kept.

Those figures land on the trial usage `accounting` object and on the trajectory (`metrics.extra`, `final_metrics.extra`, and `llm_call_count` when the server reported more than one call).

## Textual DSML tool calls

The local V15 completion is often not an OpenAI `tool_calls` array. It is text, either official `｜DSML｜` blocks or a degraded `<invoke>` (sometimes wrapped in `<bash>`). With `agent.local.dsml: true`, miniswen reads that text into the bash tool it already sent. The only accepted shape is `bash` with a string `command` (`string="true"`). Any other tool, parameter, or flag is dropped and recorded. Arguments are not filled in.

`bash_call_limit: 1` keeps the first exact command in that response and records the number of later valid calls under `metrics.extra.dsml.omitted`. Different commands are not merged. The raw text is kept on that same record. Prompt and completion totals stay the full generation, including tokens spent on calls that were not run. The parser does not call the model again and does not execute anything by itself.

The smoke bench turns this on. Time, step, and cost budgets are unchanged.

## Smoke, then the corpus

The only task here is `smoke`. Its grader is `verification_test.rb`, not the instruction. Oracle should score 1 and nop should score 0. Neither talks to the router.

```sh
lemans run --bench examples/ds41-local --agent oracle --backend docker
lemans run --bench examples/ds41-local --agent nop --backend docker
```

Do not start the 46-task Rails DHH corpus from here. When you do, point the same `local/direct` and `local/lecore` models at it and run it on the machine with the GGUF, using the Docker backend and Ruby 3.4. That corpus is not vendored into this repository.
