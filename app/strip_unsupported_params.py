"""
Custom LiteLLM callback to strip parameters unsupported by Vertex AI's
Anthropic endpoint before pass-through forwarding.

Problem: Claude Code sends `output_config` (an Anthropic API feature) but
Vertex AI's streamRawPredict endpoint rejects it with:
  "output_config: Extra inputs are not permitted"

Solution: Remove unsupported params in the pre_call_hook before the request
is forwarded to Vertex AI.
"""

from litellm.integrations.custom_logger import CustomLogger


# Parameters that Anthropic's direct API supports but Vertex AI does not
UNSUPPORTED_VERTEX_PARAMS = [
    "output_config",
]


class StripUnsupportedParams(CustomLogger):
    async def async_pre_call_hook(
        self,
        user_api_key_dict,
        cache,
        data: dict,
        call_type: str,
    ) -> dict:
        if call_type == "pass_through_endpoint" and isinstance(data, dict):
            for param in UNSUPPORTED_VERTEX_PARAMS:
                data.pop(param, None)
        return data


strip_unsupported_params = StripUnsupportedParams()
