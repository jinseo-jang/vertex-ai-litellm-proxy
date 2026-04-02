# 공식 LiteLLM 이미지를 사용합니다.
FROM ghcr.io/berriai/litellm:main-latest

# 작업 디렉토리 설정
WORKDIR /app

# 설정 파일과 커스텀 콜백을 복사합니다.
COPY config.yaml .
COPY strip_unsupported_params.py .

# Cloud Run을 위한 포트 설정 (LiteLLM 기본값은 4000이나 8080으로 실행)
EXPOSE 8080

# 직접 실행 명령어를 정의합니다.
CMD ["--config", "config.yaml", "--port", "8080", "--detailed_debug"]
