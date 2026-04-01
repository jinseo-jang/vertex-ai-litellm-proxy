# Vertex AI LiteLLM Proxy

LiteLLM을 사용하여 Google Cloud Vertex AI의 Anthropic 모델을 안전하게 노출하는 프록시 아키텍처입니다. 이 저장소는 Terraform을 이용한 완전 자동화된 인프라 배포(IaC) 코드를 제공합니다.

## 아키텍처 개요

본 프로젝트는 개발자에게 안전하게 API를 제공하면서도 관리자 대시보드를 철저히 보호하기 위한 이중 경로(Dual-path) 보안 모델을 구축합니다. 또한, 프록시에서 Vertex AI로 향하는 모든 아웃바운드 트래픽이 퍼블릭 인터넷을 거치지 않고 Google Cloud 내부망(Private Network Backbone) 내에서만 이동하도록 보장합니다.

### 아키텍처 다이어그램

```mermaid
graph TD
    subgraph External Network
        User[API Client / Claude Code]
        Admin[Administrator Browser]
    end

    subgraph External HTTP/S Load Balancer
        URLMap[URL Map Routing]
        CA[Cloud Armor<br/>IP Whitelisting]
        IAP[Identity-Aware Proxy<br/>Google Auth]
        
        User -- "HTTPS /v1/*" --> URLMap
        Admin -- "HTTPS /ui/*" --> URLMap
        
        URLMap -- "/v1/*" --> CA
        URLMap -- "/ui/*" --> IAP
    end

    subgraph Virtual Private Cloud (VPC)
        CR[Cloud Run<br/>LiteLLM Proxy Container]
        DB[(Cloud SQL<br/>PostgreSQL 15)]
        PSC[Private Service Connect<br/>Reserved IP: 192.168.255.240]
        DNS[Cloud DNS Private Zone<br/>*.googleapis.com]
        
        CA -- "Allowed IPs Only" --> CR
        IAP -- "Authenticated Identity" --> CR
        
        CR -- "Direct VPC Egress" --> DB
        CR -- "Egress: ALL_TRAFFIC" --> DNS
        DNS -- "Resolve API" --> PSC
    end

    subgraph Google APIs
        SM[Secret Manager]
        VAI[Vertex AI<br/>Anthropic Models]
        
        CR -- "Read Keys" --> SM
        PSC -- "Private Backbone" --> VAI
    end
```

## 아키텍처 구성 요소

*   **External HTTP(S) Load Balancer**: 단일 진입점 역할을 수행합니다. SSL 연결을 처리하고 URL 경로에 따라 트래픽을 분기합니다.
*   **Cloud Armor**: `/v1/*` 경로에 적용됩니다. 허용 목록(Whitelist)에 등록된 IP 주소에서만 API 접근을 허용하여, 비인가된 프로그래밍 방식의 호출을 네트워크 수준에서 차단합니다.
*   **Identity-Aware Proxy (IAP)**: `/ui/*` 경로에 적용됩니다. LiteLLM 관리자 대시보드에 접근하기 전 Google 계정 로그인을 강제합니다.
*   **Cloud Run (LiteLLM)**: 핵심 프록시 애플리케이션입니다. 인터넷을 통한 직접 접근을 막기 위해 `INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER`로 설정되며, 모든 아웃바운드 요청을 VPC 내부로 강제하기 위해 `egress = "ALL_TRAFFIC"`으로 구성됩니다.
*   **Cloud SQL (PostgreSQL)**: 가상 키, 사용자 구성 및 텔레메트리 데이터를 관리하는 영구 데이터 저장소입니다. Private IP로 구성되어 외부 노출이 없으며, Cloud Run의 Direct VPC Egress를 통해 접근됩니다.
*   **Secret Manager**: LiteLLM 마스터 키 및 데이터베이스 접속 정보와 같은 민감한 데이터를 안전하게 보관합니다.
*   **Private Service Connect (PSC) & Cloud DNS**: `*.googleapis.com`으로 향하는 요청을 내부 예약 IP(`192.168.255.240`)로 가로챕니다. 이를 통해 LiteLLM이 Vertex AI를 호출할 때 퍼블릭 인터넷을 타지 않고 트래픽을 완벽하게 격리합니다.

## VPC Service Controls (VPC-SC) 설정 보류 사유

VPC-SC는 퍼블릭 엔드포인트 우회를 방지하는 표준 메커니즘이지만, 본 구성에서는 의도적으로 배제되었습니다. Vertex AI API(`aiplatform.googleapis.com`)에 VPC-SC 경계를 적용할 경우, Anthropic 모델의 핵심 기능 중 하나인 웹 검색(Web-Search) 기반 그라운딩(Grounding) 기능이 차단되는 기술적 제약이 존재합니다. 현재의 PSC 구성만으로도 모델의 기능을 제한하지 않으면서 충분한 네트워크 격리를 제공할 수 있습니다.

## 배포 가이드

### 사전 준비 사항

1. Google Cloud SDK (`gcloud`) 설치 및 인증.
2. Terraform (`>= 1.5.0`) 설치.
3. 사용할 커스텀 도메인 소유 및 DNS 제어 권한.
4. Artifact Registry에 업로드된 LiteLLM Docker 이미지.

### 배포 단계

1. `variables.tf` 파일을 수정하거나 `terraform.tfvars` 파일을 생성하여 환경 변수를 프로젝트에 맞게 설정합니다:
   ```hcl
   project_id      = "your-gcp-project-id"
   region          = "us-central1"
   domain_name     = "your.domain.com"
   allowed_ip      = "203.0.113.1/32"
   iap_admin_email = "admin@yourcompany.com"
   ```

2. Terraform 구성을 초기화하고 배포를 실행합니다:
   ```bash
   cd terraform_litellm
   terraform init
   terraform apply
   ```

3. 배포가 완료되면 출력된 글로벌 고정 IP 주소를 도메인(A 레코드)에 연결합니다.

4. Google 관리형 SSL 인증서 발급 및 글로벌 부하 분산기 규칙 전파까지 10~20분 정도 대기합니다.

## 사용 방법

### 대시보드 접근 (/ui)
웹 브라우저에서 `https://your.domain.com/ui`로 접속합니다. Google 계정을 통한 IAP 인증 화면이 나타납니다. 인증 후 나타나는 화면에 `LITELLM_MASTER_KEY`를 입력하면 관리자 패널을 사용할 수 있습니다.

### API 접근 (/v1/*)
Claude Code나 curl 같은 클라이언트를 구성할 때 다음과 같이 엔드포인트를 설정합니다. 요청은 반드시 Cloud Armor 정책에 허용된 IP 주소에서 발생해야 합니다.

```json
{
  "endpoint": "https://your.domain.com/v1",
  "api_key": "sk-your-virtual-key",
  "model": "claude-sonnet-4-6"
}
```
