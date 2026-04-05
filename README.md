# 상품가격 적재 프로세스 - 6주 기술 학습 계획

> **이 파일의 목적**: 인프라팀 주니어 개발자가 팀 실제 아키텍처와 유사한 POC 환경을 구축하며
> 핵심 기술 원리를 이해하는 학습 로드맵. 단순 구현이 아닌 **"왜 이렇게 동작하는가"** 이해가 목적.
> 6주 학습 후 1주간 상품가격 적재 비즈니스 통합 구현 예정.
> **새 세션에서도 이 파일만 읽으면 아키텍처 전체 맥락을 파악하고 질문에 답할 수 있도록 작성됨.**

---

## 전체 시스템 아키텍처

### 요청 흐름 (Request Flow)

```
Client (MO / PC)
    │
    ▼
방화벽 (Firewall)
    │  외부 트래픽 필터링 (포트/IP 기반 접근 제어)
    ▼
NLB (Network Load Balancer)  ← L4, TCP 레벨 처리
    │  고정 IP 제공, 극저지연, TLS Termination 가능
    ▼
Web Server (Apache httpd)  ← EC2, Set A or B
    │
    ├─── /img/**  ────────────────────────────────► S3 (정적 이미지)
    │    (Apache ProxyPass or Redirect → S3 URL)
    │
    └─── /api/**  ────────────────────────────────► ALB (Application Load Balancer)  ← L7
                  (Apache conf: ProxyPass /api → ALB)   │  Header/Path 기반 라우팅
                                                         ▼
                                                   WAS (Spring Boot 등)  ← EC2, Set A or B
                                                         │
                                                         ▼
                                                   Redis (가격 캐시)
                                                         │
                                                         ▼
                                                   RDS (가격 원천 DB)
```

**핵심 포인트**:
- NLB → Web(Apache): L4이므로 HTTP 헤더를 보지 않음. 단순 TCP 포워딩
- Web(Apache) → ALB: Apache `ProxyPass` 설정으로 `/api` 경로를 ALB로 전달
- Web(Apache) → S3: Apache `RewriteRule` 또는 `ProxyPass`로 S3 버킷 URL로 리다이렉트
- ALB → WAS: L7이므로 Host 헤더, Path, 커스텀 헤더 기반 라우팅 가능 → Set A/B 분기 가능

### 배포 환경 구조 (Lane / Set / stageNo)

| Lane    | Set | stageNo | 목적                              |
|---------|-----|---------|-----------------------------------|
| primary | A/B | -       | 운영 배포. Blue-Green 무중단 배포  |
| stage   | A/B | 1/2/3   | 개발 배포. 프로젝트별 독립 환경    |
| preview | A/B | -       | 프리뷰 배포. QA/검수용             |

- **총 Set 수**: primary×2 + stage×6 + preview×2 = **10개 Set**
- 각 Set은 Web(Apache) + WAS 한 쌍으로 구성
- **Set A = Blue (현재 운영)**, **Set B = Green (신규 배포 대기)**
- 배포 시 Green에 배포 → Health Check → ALB 트래픽 전환 → Blue 역할 교체

### EC2 인스턴스 Tag 전략

```
application: mo | pc
lane:        primary | stage | preview
stageNo:     1 | 2 | 3  (stage lane 에서만 사용)
set:         A | B
role:        web | was
```

**태그 활용 목적**: 배포 스크립트에서 AWS CLI로 대상 인스턴스를 동적으로 조회하기 위함.
IaC 없이도 `describe-instances --filters tag:lane=stage tag:stageNo=2 tag:set=B` 로 대상 특정 가능.

### 가격 데이터 파이프라인

```
RDS (가격 원천 DB)
    │  binlog CDC
    ▼
AWS DMS (Database Migration Service)
    │  변경분 캡처 → Kafka produce
    ▼
Apache Kafka
    ├── Topic: price-events-setA  (Set A Consumer만 구독)
    └── Topic: price-events-setB  (Set B Consumer만 구독)
    │
    ▼
Kafka Consumer (WAS 내부 or 별도 서비스)
    │  set 구분값 파싱 → 분기 저장
    ▼
Redis
    ├── price:setA:productId:{id}  →  Hash { regular, sale, ... }
    └── price:setB:productId:{id}  →  Hash { regular, sale, ... }
```

**예약 가격 경로 (Cron)**:
```
Batch Scheduler (Cron)
    │  매 N분마다 DB 조회: scheduled_at <= now()
    ▼
Kafka produce → price-events-setA / price-events-setB
    ▼
Redis 갱신
```

### 로그 수집 파이프라인 (ELK)

```
EC2 (Web/WAS)
    │  /var/log/httpd/access.log, app.log 등
    ▼
Filebeat (각 EC2에 설치)
    │  파일 변경 감지 (inode tracking)
    ▼
Logstash
    │  Grok 파싱: lane, set, stageNo 필드 추출
    ▼
Elasticsearch
    │  인덱싱 (Inverted Index, Shard/Replica)
    ▼
Kibana
    Set별, Lane별 로그 대시보드
```

---

## Week 1: AWS 네트워킹 & 인프라 기초

**이 주차의 목표**: 이후 모든 실습의 기반이 되는 네트워크 구조를 손으로 직접 만들고 원리를 이해한다.

### 핵심 개념

- **VPC 내부 동작 원리**: CIDR 블록 설계, Subnet(Public/Private), Route Table, Internet Gateway, NAT Gateway
- **Security Group vs NACL**: Stateful(SG) vs Stateless(NACL) 방화벽 차이 — 왜 두 개가 공존하는가
- **IAM Role**: EC2 인스턴스 프로파일, Policy 구조 (어떻게 권한이 EC2 내부 프로세스까지 전파되는가)
- **EC2**: AMI, Launch Template, User Data 스크립트 (첫 부팅 시 자동 설정)
- **NLB vs ALB**: L4(NLB)와 L7(ALB)의 차이 — 이 아키텍처에서 왜 앞단에 NLB를 쓰는가
  - NLB: 고정 IP, 극저지연, TCP/UDP 레벨 → 방화벽 IP Whitelist 등록에 유리
  - ALB: HTTP 헤더/Path 인식 → Set A/B 라우팅에 유리

### 핵심 질문 (주말까지 스스로 답할 수 있어야 함)

1. Private Subnet의 EC2가 인터넷에 나가는 경로는? (NAT Gateway의 역할)
2. Security Group은 왜 "Stateful"인가? (응답 트래픽에 별도 규칙이 없어도 되는 이유)
3. IAM Role과 IAM User의 차이는? (EC2가 S3에 접근할 때 Key를 파일로 저장하지 않아도 되는 이유)
4. 이 아키텍처에서 NLB가 ALB 앞에 있는 이유는? (고정 IP의 필요성)

### 실습

- VPC 직접 설계: Public Subnet (NLB, Bastion), Private Subnet (Web, WAS, Redis, RDS)
- EC2 Launch Template 생성 — tag 포함: `application=mo, lane=primary, set=A, role=web`
- Bastion Host → Private EC2 SSH 접속 (Jump Host 패턴)
- Security Group 설계: NLB → Web 허용, Web → ALB 허용, ALB → WAS 허용 등 최소 권한 원칙 적용

---

## Week 2: NLB + ALB + Target Group + ASG — Blue-Green 배포 원리

**이 주차의 목표**: NLB(L4) → Apache(Web) → ALB(L7) → WAS 전체 트래픽 흐름을 직접 구성하고, Blue-Green 전환 원리를 체험한다.

### 핵심 개념

- **NLB 동작 원리**: L4 로드밸런서, TCP 그대로 포워딩, 헬스체크 (TCP/HTTP)
- **ALB 동작 원리**: L7 로드밸런서, Listener → Rule → Target Group 라우팅
  - Listener Rule: 헤더(`X-Deploy-Set: A/B`), Path, Host 기반 분기
- **Target Group**: Health Check 판단 기준 (경로, 임계값, 간격), Deregistration Delay (드레이닝)
- **ASG**: Launch Template 연결, Desired/Min/Max, Scaling Policy (Step vs Target Tracking)
- **Blue-Green 배포 vs Rolling vs Canary**: 각각 트레이드오프
- **무중단 배포 원리**: Connection Draining이 왜 필요한가 (기존 커넥션 처리 완료 후 인스턴스 제거)
- **Apache ProxyPass 설정**: `/api` 경로를 ALB DNS로 포워딩하는 httpd.conf 구성

### Apache conf 핵심 (Web 서버 역할)

```apache
# /img → S3 리다이렉트
RewriteRule ^/img/(.*)$ https://my-bucket.s3.amazonaws.com/img/$1 [R=301,L]

# /api → ALB 포워딩 (Reverse Proxy)
ProxyPass        /api  http://internal-alb-dns.ap-northeast-2.elb.amazonaws.com/api
ProxyPassReverse /api  http://internal-alb-dns.ap-northeast-2.elb.amazonaws.com/api
```

### 핵심 질문

1. ALB Listener Rule에서 Header 기반 라우팅은 어떻게 동작하는가?
2. Health Check 실패 시 ASG는 인스턴스를 어떻게 처리하는가? (교체 vs 제거)
3. Blue → Green 전환 시 기존 연결(세션)은 어떻게 처리되는가? (Draining 시간 동안 무슨 일이 벌어지는가)
4. NLB는 클라이언트 IP를 WAS까지 어떻게 전달하는가? (X-Forwarded-For vs Proxy Protocol)

### 실습

- NLB → Web(Apache) EC2 연결 (Target Group: instance 타입)
- Apache httpd 설치 + ProxyPass 설정 (img → S3, api → ALB)
- ALB + Listener Rule 설정 (Path `/api/*` → WAS Target Group)
- Target Group A (Blue WAS), Target Group B (Green WAS) 생성
- ASG에 각 TG 연결, Desired 수 조정하며 트래픽 전환 실험
- Draining 시간(기본 300초) 조정 후 전환 전/후 응답 직접 측정

---

## Week 3: Tag 기반 배포 자동화 스크립트

**이 주차의 목표**: EC2 Tag를 배포 식별자로 활용하여 lane/set/stageNo 조합별로 자동 배포하는 스크립트를 작성하고, Kafka Consumer와의 연동 방식을 이해한다.

### 핵심 개념

- **EC2 Tag 전략**: Tag를 식별자로 사용하는 이유 — IaC 없이도 대상 동적 조회 가능
- **Zip 배포 패키지 구조**: 빌드 아티팩트 + 메타데이터(배포시각, 커밋해시, lane, set, stageNo)
- **배포 스크립트 흐름**:
  ```
  Build → zip 패키징(tag 메타 포함) → S3 Upload
  → EC2 Tag 조회 (AWS CLI describe-instances)
  → 대상 인스턴스 식별 → zip 전송 (SSM or SCP)
  → 서비스 재시작 → Health Check
  → ALB TG 트래픽 전환 (modify-listener / modify-rule)
  ```
- **AWS CLI 핵심 명령**:
  ```bash
  aws ec2 describe-instances \
    --filters "Name=tag:lane,Values=stage" \
              "Name=tag:stageNo,Values=2" \
              "Name=tag:set,Values=B" \
    --query "Reservations[*].Instances[*].InstanceId"
  ```
- **Kafka 파이프라인 조절**: 배포 중 해당 Set의 Consumer 일시 중단 → 배포 완료 후 재개
  - 이유: 배포 도중 Consumer가 새 버전/구 버전 혼재 상태에서 메시지를 처리하면 가격 데이터 불일치 위험

### 핵심 질문

1. `lane=stage, stageNo=2, set=B` 인 인스턴스만 골라내는 AWS CLI 명령 전체를 써보라
2. zip 파일 안에 어떤 메타데이터를 포함해야 배포 이력 추적이 가능한가?
3. 배포 중 Kafka Consumer를 멈추지 않으면 어떤 문제가 생기는가? (가격 일관성 관점)
4. SSM Session Manager를 SCP 대신 쓰는 이유는? (보안 관점)

### 실습

```bash
# 목표 스크립트 인터페이스
deploy.sh --app mo --lane stage --stageNo 2 --set B
```

구현 흐름:
1. Tag 기반 인스턴스 ID 조회
2. S3에서 zip 다운로드 (SSM Run Command)
3. 서비스 재시작 (systemd)
4. Health Check (curl 루프)
5. ALB TG 트래픽 전환 (`aws elbv2 modify-listener`)
6. lane/stageNo/set 조합 10가지 시나리오 검증

---

## Week 4: Apache Kafka 핵심 원리 + AWS DMS CDC

**이 주차의 목표**: Kafka의 내부 동작 원리(Partition, Offset, Rebalancing)를 직접 실험으로 확인하고, DMS를 통한 CDC 파이프라인을 구성한다.

### 핵심 개념

- **Kafka 아키텍처**: Broker, KRaft(ZooKeeper 대체, 최신), Topic, Partition, Offset, Segment
- **Producer**: Partitioner 전략 (key hash vs round-robin), acks 설정 (0=fire-forget / 1=leader확인 / all=ISR전체확인)
- **Consumer Group**: Partition 할당 원리, Rebalancing (Consumer 추가/제거 시 재할당), Offset Commit
  - **at-least-once vs exactly-once**: 가격 적재에서 중복 처리 허용 여부 설계
- **Set 기반 토픽 분리 전략**:
  ```
  price-events-setA   ← Set A WAS Consumer만 구독
  price-events-setB   ← Set B WAS Consumer만 구독
  price-events-all    ← 필요 시 전체 이벤트 감사용
  ```
- **AWS DMS CDC (Change Data Capture)**:
  - RDS MySQL binlog(row-based) 기반 변경 감지
  - DMS Replication Instance → Source Endpoint(RDS) → Target Endpoint(Kafka)
  - binlog 이벤트 타입: INSERT/UPDATE/DELETE → Kafka 메시지로 변환
- **Cron + Kafka 패턴**: 예약 가격은 DMS가 아닌 Batch가 직접 produce (DB `scheduled_at <= now()` 조회)

### 핵심 질문

1. Partition 수와 Consumer 수의 관계는? Consumer 수 > Partition 수 이면 어떻게 되는가?
2. Consumer가 죽었다 재시작하면 어디서부터 읽는가? (auto.offset.reset 옵션)
3. DMS는 RDS binlog의 어떤 이벤트를 어떻게 Kafka 메시지 구조로 변환하는가?
4. Rebalancing 중에 메시지 처리가 잠깐 멈추는 이유는? 어떻게 최소화하는가?

### 실습

```yaml
# docker-compose.yml 구성 목표
services:
  kafka-1, kafka-2, kafka-3:  # KRaft 모드, Broker 3대
  kafka-ui:                   # 토픽/Consumer 상태 시각화
```

- price-events-setA / price-events-setB 토픽 생성 (partition=3, replication-factor=2)
- Python Producer: RDS 가격 데이터 → Kafka produce (set 구분값 헤더 또는 페이로드 포함)
- Consumer Group 실험: Consumer 추가/제거 → Rebalancing 로그 직접 관찰
- AWS DMS 설정: RDS MySQL binlog → Kafka CDC 파이프라인 구성 및 메시지 구조 확인

---

## Week 5: Redis 캐시 전략 + 가격 적재 파이프라인

**이 주차의 목표**: Redis 데이터 구조를 이해하고 Set A/B 분리 저장 전략을 설계하며, Kafka → Redis 전체 파이프라인을 완성한다.

### 핵심 개념

- **Redis 데이터 구조 선택 기준**:
  - `String`: `price:setA:123` = JSON blob → 단순하지만 부분 업데이트 불가
  - `Hash`: `price:setA:123` → `{ regular: 10000, sale: 8000, updatedAt: ... }` → 필드별 접근/갱신 가능 → **가격 캐시에 적합**
  - `Sorted Set`: 가격순 정렬이 필요할 때 (랭킹, 범위 조회)

- **Set A/B 분리 저장 구조**:
  ```
  HSET price:setA:productId:123  regular 10000  sale 8000  updatedAt 1700000000
  HSET price:setB:productId:123  regular 10000  sale 7500  updatedAt 1700000001
  ```

- **TTL 전략**: 가격 데이터는 만료 기준이 명확하지 않으므로 명시적 갱신 + 긴 TTL (24h 등) 또는 TTL 없이 명시적 삭제

- **Kafka Consumer → Redis 적재 코드 흐름**:
  ```
  메시지 수신 → set 구분값 파싱 → price:setA or price:setB 키 결정
  → HSET 저장 → Offset Commit
  ```

- **Redis Cluster vs Sentinel**: Cluster(수평 샤딩, 고가용성) vs Sentinel(단일 마스터 장애조치)
- **예약 가격 Cron 패턴**: `SELECT * FROM prices WHERE scheduled_at <= NOW() AND applied = false` → Kafka produce → Redis 갱신 → applied = true

### 핵심 질문

1. Redis Hash vs String 중 가격 데이터에 어떤 구조가 적합하고 왜인가?
2. Kafka Consumer에서 Redis 저장 실패 시 어떻게 처리해야 하는가? (Offset Commit 시점)
3. 가격이 빠르게 연속 변경될 때 Redis 갱신 순서(Ordering)를 보장하는 방법은? (Kafka Partition key 전략)
4. Set A 인스턴스는 `price:setB:*` 키를 읽을 수 있는가? 읽으면 안 되는 이유는?

### 실습

- Redis 구성 (Docker 또는 AWS ElastiCache for Redis)
- Kafka Consumer 작성: set 구분값 파싱 → `price:setA` / `price:setB` 분기 저장
- Cron 스크립트: 매 1분마다 예약 가격 체크 → Kafka produce
- 가격 변경 시뮬레이션: DB UPDATE → DMS → Kafka → Redis 흐름 전체 추적 (각 단계 지연 측정)

---

## Week 6: ELK 스택 — 로그 수집 & 모니터링

**이 주차의 목표**: Filebeat → Logstash → Elasticsearch → Kibana 전체 흐름을 구성하고, Apache 로그와 WAS 로그를 Set/Lane별로 구분하여 시각화한다.

### 핵심 개념

- **Filebeat 동작 원리**: inode + offset 기반 파일 추적 (파일 삭제/rotate 후에도 새 파일 자동 감지)
- **Log Rotation 원리**: `logrotate` → 파일 rename → 새 파일 생성 → Filebeat inode 변경 감지 → 새 파일부터 읽기
- **Logstash 파이프라인**:
  ```
  input  { beats { port => 5044 } }
  filter {
    grok { match => { "message" => "%{COMBINEDAPACHELOG}" } }
    # lane, set, stageNo 는 Filebeat fields 로 주입
  }
  output { elasticsearch { hosts => ["es:9200"] index => "logs-%{lane}-%{set}-%{+YYYY.MM.dd}" } }
  ```
- **Filebeat fields 활용**: 각 EC2에 배포된 Filebeat 설정에 tag 정보 주입
  ```yaml
  fields:
    lane: stage
    stageNo: "2"
    set: B
    role: web
  ```
- **Elasticsearch 내부**: Inverted Index (전문 검색 원리), Shard/Replica (분산 저장), Index Template (자동 매핑)
- **Kibana KQL**:
  ```
  lane: "stage" AND set: "B" AND stageNo: "2"
  ```
- **SSH 로그 접속 패턴**: Bastion → Private EC2 SSH → `tail -f /var/log/app.log`

### 핵심 질문

1. Filebeat는 파일이 rotate 됐을 때 어떻게 새 파일을 감지하는가? (inode 변경 원리)
2. Logstash Grok 파싱 실패 시 해당 로그는 어떻게 처리되는가? (`_grokparsefailure` 태그)
3. Elasticsearch Shard 수를 나중에 변경할 수 없는 이유는?
4. Apache access log에서 NLB가 클라이언트 IP를 어떻게 전달하는가? (X-Forwarded-For or Proxy Protocol)

### 실습

```yaml
# docker-compose.yml 구성 목표
services:
  elasticsearch:  # 단일 노드 (학습용)
  logstash:       # Grok 파이프라인
  kibana:         # 대시보드
  filebeat:       # 로컬 로그 파일 수집
```

- WAS/Apache 로그 샘플 생성 → Filebeat → Logstash → Elasticsearch 흐름 확인
- Grok 패턴으로 lane/set/stageNo 필드 추출
- Kibana에서 Set별, Lane별 로그 대시보드 구성 (Bar chart: 요청수 per set)
- `logrotate -f` 명령으로 강제 rotate → Filebeat 재감지 확인

---

## Week 7 (구현 주간): 통합 비즈니스 구현

6주간 학습한 기술을 조합하여 상품가격 적재 프로세스 전체 구현:

| 단계 | 내용 |
|------|------|
| 1 | VPC + Subnet + Security Group 설계 |
| 2 | EC2 Launch Template (Web/WAS, tag 포함) |
| 3 | NLB → Web(Apache) → ALB → WAS 트래픽 흐름 구성 |
| 4 | Apache conf: img→S3, api→ALB ProxyPass 설정 |
| 5 | RDS + DMS + Kafka 가격 변경 파이프라인 |
| 6 | Cron 기반 예약 가격 이벤트 처리 |
| 7 | Kafka Consumer → Redis (Set A/B 분리 저장) |
| 8 | Filebeat + ELK 스택 연동 → Kibana 대시보드 |
| 9 | deploy.sh 완성 → Blue-Green 전환 시나리오 실행 |
| 10 | 장애 시나리오: Consumer 다운, Health Check 실패, Rotate 등 |

---

## 학습 원칙

| 원칙 | 내용 |
|------|------|
| **원리 우선** | 왜 이 기술이 존재하는가 → 어떻게 동작하는가 → 어떻게 쓰는가 순서로 접근 |
| **직접 깨기** | 의도적으로 장애 상황(Consumer 죽이기, Health Check 실패 등)을 만들어 복구 흐름 관찰 |
| **비용 주의** | 실습 후 리소스 즉시 삭제 (특히 NAT Gateway, ALB, ElastiCache — Free Tier 미적용) |
| **기록** | 주차별 "무엇을 몰랐고, 어떻게 이해했는가" 기록 |
| **로컬 우선** | Kafka, ELK는 Docker Compose로 로컬 먼저 → 원리 이해 후 AWS 이관 |
