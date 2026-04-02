# Troubleshooting

## output_config: Extra inputs are not permitted

### Symptom

When calling Anthropic models on Vertex AI through the LiteLLM proxy via Claude Code, the following 400 error occurs:

```json
{
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "message": "output_config: Extra inputs are not permitted"
  }
}
```

The error originates from LiteLLM's pass-through endpoint, with the traceback pointing to:

```
litellm/proxy/pass_through_endpoints/pass_through_endpoints.py
  -> httpx.HTTPStatusError: Client error '400 Bad Request'
  -> URL: .../models/claude-haiku-4-5@20251001:streamRawPredict
```

### Root Cause

```
Claude Code --[includes output_config]--> LiteLLM /vertex_ai/v1 (pass-through)
  --> forwards request body as-is --> Vertex AI streamRawPredict
  --> Vertex AI does not support output_config --> 400 error
```

| Component | Description |
|-----------|-------------|
| **Claude Code** | Includes the `output_config` parameter (a recent Anthropic API feature) in the request body |
| **LiteLLM pass-through** | Forwards the request body to Vertex AI without modification via `/vertex_ai/v1/...`. Only strips LiteLLM-specific parameters (`model`, `api_key`, etc.) but does not filter provider-incompatible parameters |
| **Vertex AI** | The `streamRawPredict` endpoint does not recognize `output_config` and returns a 400 error |

`output_config` is a parameter supported by the direct Anthropic API (for structured output configuration, etc.) but is not yet supported by the Vertex AI Anthropic endpoint.

#### Why does this only happen through LiteLLM, not when Claude Code calls Vertex AI directly?

When Claude Code calls Vertex AI directly (with GCP ADC authentication), the Anthropic SDK's built-in Vertex AI adapter automatically strips parameters that Vertex AI does not support, including `output_config`. The request body is sanitized before it reaches the `streamRawPredict` endpoint.

However, when Claude Code is configured with `CLAUDE_CODE_SKIP_VERTEX_AUTH=1` and a custom `ANTHROPIC_VERTEX_BASE_URL` pointing to the LiteLLM proxy, the SDK takes a different request construction path that bypasses this parameter filtering. As a result, `output_config` is included in the request body. Since LiteLLM's pass-through endpoint forwards the body as-is, the unsupported parameter reaches Vertex AI and triggers the 400 error.

|  | Direct Vertex AI | Via LiteLLM Proxy |
|--|------------------|-------------------|
| Auth | GCP ADC (service account) | `CLAUDE_CODE_SKIP_VERTEX_AUTH=1` + LiteLLM virtual key |
| SDK path | Vertex AI dedicated adapter | Auth-bypass path |
| Parameter filtering | SDK strips unsupported params | No filtering; body forwarded as-is |
| `output_config` | **Removed by SDK** | **Included** → 400 error |

### Related Issues

- [BerriAI/litellm#21407](https://github.com/BerriAI/litellm/issues/21407) - Vertex AI `output_config` bug report
- [BerriAI/litellm#22884](https://github.com/BerriAI/litellm/pull/22884) - Official fix PR (merged 2026-03-05)

PR #22884 removes `output_config` in LiteLLM's transformation layer (standard completion routes). However, the **raw proxy pass-through path** (`pass_through_endpoints.py`) used by Claude Code does not go through the transformation layer, so a Docker image update alone may not resolve the issue.

### Resolution

> **Important:** [PR #22884](https://github.com/BerriAI/litellm/pull/22884) fixes `output_config` stripping in LiteLLM's transformation layer (standard `/v1/messages` completion routes), but **does NOT fix the pass-through path** (`/vertex_ai/v1/...`) used by Claude Code. This was verified by deploying the latest LiteLLM image (post-PR #22884) without the custom callback — the `output_config` error persisted. **The custom callback below is required** to resolve this issue for pass-through endpoints.

#### Custom Callback to Strip Unsupported Parameters

Use LiteLLM's `CustomLogger.async_pre_call_hook` to register a callback that removes unsupported parameters before the pass-through request is forwarded to Vertex AI.

**`app/strip_unsupported_params.py`**:
```python
from litellm.integrations.custom_logger import CustomLogger

UNSUPPORTED_VERTEX_PARAMS = ["output_config"]

class StripUnsupportedParams(CustomLogger):
    async def async_pre_call_hook(self, user_api_key_dict, cache, data: dict, call_type: str) -> dict:
        if call_type == "pass_through_endpoint" and isinstance(data, dict):
            for param in UNSUPPORTED_VERTEX_PARAMS:
                data.pop(param, None)
        return data

strip_unsupported_params = StripUnsupportedParams()
```

**Register the callback in `app/config.yaml`**:
```yaml
litellm_settings:
  callbacks:
    - strip_unsupported_params.strip_unsupported_params
```

**Add the file copy to `app/Dockerfile`**:
```dockerfile
COPY strip_unsupported_params.py .
```

If new unsupported parameters are introduced in the future, simply add the parameter name to the `UNSUPPORTED_VERTEX_PARAMS` list.

### Verification

After rebuilding and redeploying, the following feature tests were executed to confirm normal operation.

```bash
export BASE="https://YOUR_DOMAIN/vertex_ai/v1"
export PROJECT="YOUR_PROJECT_ID"
export LOCATION="global"
export API_KEY="YOUR_API_KEY"
export MODEL="claude-haiku-4-5@20251001"
export ENDPOINT="$BASE/projects/$PROJECT/locations/$LOCATION/publishers/anthropic/models/$MODEL:rawPredict"
```

| # | Feature | Status | Notes |
|---|---------|--------|-------|
| 1 | Basic Messages | PASS | Standard request/response |
| 2 | Streaming | PASS | SSE events received correctly |
| 3 | Extended Thinking | PASS | Thinking block + response returned |
| 4 | Tool Use | PASS | Function calling works correctly |
| 5 | Vision (base64) | PASS | Image recognition works. URL-based source is not supported by Vertex AI |
| 6 | Multi-turn | PASS | System prompt + conversation history works |
| 7 | Token Counting | N/A | Not supported by the Vertex AI Anthropic endpoint |
| 8 | Citations | PASS | Document citation with `char_location` returned correctly |

**7 out of 8 features verified.** Token Counting is a limitation of the Vertex AI Anthropic endpoint itself and is unrelated to the LiteLLM proxy.
