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

### Related Issues

- [BerriAI/litellm#21407](https://github.com/BerriAI/litellm/issues/21407) - Vertex AI `output_config` bug report
- [BerriAI/litellm#22884](https://github.com/BerriAI/litellm/pull/22884) - Official fix PR (merged 2026-03-05)

PR #22884 removes `output_config` in LiteLLM's transformation layer (standard completion routes). However, the **raw proxy pass-through path** (`pass_through_endpoints.py`) used by Claude Code does not go through the transformation layer, so a Docker image update alone may not resolve the issue.

### Resolution

A two-step approach is used to resolve this.

#### Step 1: Update the LiteLLM Docker Image

Rebuild with the latest image that includes PR #22884 to check if the official fix applies.

```bash
gcloud builds submit app/ \
  --tag us-central1-docker.pkg.dev/PROJECT_ID/litellm-repo/litellm-proxy:latest \
  --quiet

gcloud run services update litellm-proxy-tf \
  --region us-central1 \
  --image us-central1-docker.pkg.dev/PROJECT_ID/litellm-repo/litellm-proxy:latest
```

#### Step 2: Custom Callback to Strip Parameters (if Step 1 does not resolve the issue)

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
