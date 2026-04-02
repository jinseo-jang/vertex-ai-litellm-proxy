# Troubleshooting

## output_config: Extra inputs are not permitted

### Symptom

Claude Code에서 LiteLLM 프록시를 통해 Vertex AI의 Anthropic 모델을 호출할 때, 다음과 같은 400 에러가 발생한다.

```json
{
  "type": "error",
  "error": {
    "type": "invalid_request_error",
    "message": "output_config: Extra inputs are not permitted"
  }
}
```

에러는 LiteLLM의 pass-through 엔드포인트에서 발생하며, traceback은 다음 경로를 가리킨다:

```
litellm/proxy/pass_through_endpoints/pass_through_endpoints.py
  -> httpx.HTTPStatusError: Client error '400 Bad Request'
  -> URL: .../models/claude-haiku-4-5@20251001:streamRawPredict
```

### Root Cause

```
Claude Code --[output_config 포함]--> LiteLLM /vertex_ai/v1 (pass-through)
  --> 요청 body 그대로 전달 --> Vertex AI streamRawPredict
  --> Vertex AI가 output_config 미지원 --> 400 에러
```

| 구간 | 설명 |
|------|------|
| **Claude Code** | 최신 Anthropic API 기능인 `output_config` 파라미터를 요청 body에 포함하여 전송 |
| **LiteLLM pass-through** | `/vertex_ai/v1/...` 경로로 들어온 요청의 body를 수정 없이 그대로 Vertex AI로 전달. LiteLLM 자체 파라미터(`model`, `api_key` 등)만 제거하고, provider-incompatible 파라미터는 필터링하지 않음 |
| **Vertex AI** | `streamRawPredict` 엔드포인트가 `output_config`를 인식하지 못해 400 에러 반환 |

`output_config`는 Anthropic 직접 API에서 지원하는 파라미터(structured output 설정 등)이지만, Vertex AI의 Anthropic 엔드포인트에서는 아직 지원하지 않는다.

### Related Issues

- [BerriAI/litellm#21407](https://github.com/BerriAI/litellm/issues/21407) - Vertex AI `output_config` bug report
- [BerriAI/litellm#22884](https://github.com/BerriAI/litellm/pull/22884) - 공식 수정 PR (2026-03-05 머지)

PR #22884는 LiteLLM의 transformation 레이어(표준 completion 경로)에서 `output_config`를 제거하는 수정이다. 그러나 Claude Code가 사용하는 **raw proxy pass-through 경로**(`pass_through_endpoints.py`)에서는 transformation 레이어를 거치지 않으므로, Docker 이미지 업데이트만으로 해결되지 않을 수 있다.

### Resolution

2단계 접근법으로 해결한다.

#### Step 1: LiteLLM Docker 이미지 업데이트

PR #22884가 포함된 최신 이미지로 리빌드하여 공식 수정이 적용되는지 확인한다.

```bash
gcloud builds submit app/ \
  --tag us-central1-docker.pkg.dev/PROJECT_ID/litellm-repo/litellm-proxy:latest \
  --quiet

gcloud run services update litellm-proxy-tf \
  --region us-central1 \
  --image us-central1-docker.pkg.dev/PROJECT_ID/litellm-repo/litellm-proxy:latest
```

#### Step 2: 커스텀 콜백으로 파라미터 제거 (Step 1으로 미해결 시)

LiteLLM의 `CustomLogger.async_pre_call_hook`을 활용하여, pass-through 요청이 Vertex AI로 전달되기 전에 미지원 파라미터를 제거하는 콜백을 등록한다.

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

**`app/config.yaml`** 에 콜백 등록:
```yaml
litellm_settings:
  callbacks:
    - strip_unsupported_params.strip_unsupported_params
```

**`app/Dockerfile`** 에 파일 복사 추가:
```dockerfile
COPY strip_unsupported_params.py .
```

향후 Vertex AI에서 지원하지 않는 새로운 파라미터가 추가될 경우, `UNSUPPORTED_VERTEX_PARAMS` 리스트에 파라미터명을 추가하면 된다.

### Verification

리빌드 및 재배포 후, 아래 기능별 테스트를 실행하여 정상 동작을 확인하였다.

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
| 1 | Basic Messages | PASS | 기본 호출 정상 |
| 2 | Streaming | PASS | SSE 이벤트 정상 수신 |
| 3 | Extended Thinking | PASS | thinking 블록 + 응답 정상 |
| 4 | Tool Use | PASS | function calling 정상 |
| 5 | Vision (base64) | PASS | 이미지 인식 정상. URL 방식은 Vertex AI 미지원 |
| 6 | Multi-turn | PASS | system 프롬프트 + 대화 이력 정상 |
| 7 | Token Counting | N/A | Vertex AI Anthropic 엔드포인트 자체 미지원 |
| 8 | Citations | PASS | 문서 인용 위치(`char_location`) 정상 반환 |

**7/8 기능 정상 동작 확인.** Token Counting은 Vertex AI Anthropic 엔드포인트의 제한사항으로 LiteLLM 프록시와 무관하다.
