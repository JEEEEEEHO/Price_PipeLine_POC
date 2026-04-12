# 상품가격 적재 프로세스 - 6주 기술 학습 계획

> **이 파일의 목적**: 인프라팀 주니어 개발자가 팀 실제 아키텍처와 유사한 POC 환경을 구축하며
> 핵심 기술 원리를 이해하는 학습 로드맵. 단순 구현이 아닌 **"왜 이렇게 동작하는가"** 이해가 목적.
> 6주 학습 후 1주간 상품가격 적재 비즈니스 통합 구현 예정.
> **새 세션에서도 이 파일만 읽으면 아키텍처 전체 맥락을 파악하고 질문에 답할 수 있도록 작성됨.**
> GitHub: https://github.com/JEEEEEEHO/Price_PipeLine_POC

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
NLB (Network Load Balancer)  ← L4, TCP 레벨, 고정 IP
    ├── Listener :8088  ──────────────────────────────┐
    └── Listener :8089  ──────────────────────────────┤
                                                       │
    ▼                                                  │
Web Server (Apache httpd)  ← EC2, 하나의 인스턴스에    │
    │  두 포트를 동시에 Listen                         │
    │                                                  │
    ├── VirtualHost *:8088  (Set A 트래픽)  ◄──────────┘(8088)
    │     ├── /img/**  → S3 (정적 이미지 리다이렉트)
    │     └── /api/**  → ALB → WAS Set A (Tomcat)
    │
    └── VirtualHost *:8089  (Set B 트래픽)  ◄──────────┘(8089)
          ├── /img/**  → S3
          └── /api/**  → ALB → WAS Set B (Tomcat)
                               │
                               ▼
                         ALB (Application Load Balancer)  ← L7
                               │  포트/헤더 기반 Set A/B 분기
                               ▼
                         WAS Set A / Set B (Tomcat)  ← EC2
                               │
                               ▼
                         Redis (가격 캐시, Set A/B 키 분리)
                               │
                               ▼
                         RDS (가격 원천 DB)
```

**핵심 포인트**:
- **NLB 듀얼 포트**: 8088(Set A 전용), 8089(Set B 전용) 두 개 Listener → 동일한 Apache EC2로 포워딩
- **Apache 멀티포트**: 하나의 Apache가 8088/8089를 동시에 Listen, VirtualHost로 분기
- **Immutable 배포**: 배포 시 기존 컨테이너 수정 X → 새 Apache + Tomcat 컨테이너 쌍 생성 → 전환 → 구 컨테이너 제거
- **Blue-Green 전환**: NLB에서 8088 ↔ 8089 트래픽 전환으로 무중단 달성

### Apache VirtualHost 멀티포트 핵심 설정

```apache
Listen 8088
Listen 8089

# ─── Set A (Port 8088 = Blue) ───────────────────────────────
<VirtualHost *:8088>
    # 이미지 → S3 리다이렉트
    RewriteEngine On
    RewriteRule ^/img/(.*)$ https://my-bucket.s3.amazonaws.com/img/$1 [R=301,L]

    # API → WAS Set A (ALB 경유)
    ProxyPass        /api  http://internal-alb.elb.amazonaws.com/api
    ProxyPassReverse /api  http://internal-alb.elb.amazonaws.com/api

    # 헬스체크 엔드포인트
    ProxyPass        /health  http://tomcat-setA:8080/health
</VirtualHost>

# ─── Set B (Port 8089 = Green) ──────────────────────────────
<VirtualHost *:8089>
    RewriteEngine On
    RewriteRule ^/img/(.*)$ https://my-bucket.s3.amazonaws.com/img/$1 [R=301,L]

    ProxyPass        /api  http://internal-alb.elb.amazonaws.com/api
    ProxyPassReverse /api  http://internal-alb.elb.amazonaws.com/api

    ProxyPass        /health  http://tomcat-setB:8080/health
</VirtualHost>
```

### 배포 환경 구조 (Lane / Set / stageNo)

| Lane    | Set | stageNo | 포트        | 목적                              |
|---------|-----|---------|-------------|-----------------------------------|
| primary | A   | -       | 8088        | 운영 배포. 현재 라이브 (Blue)      |
| primary | B   | -       | 8089        | 운영 배포. 신규 배포 대기 (Green)  |
| stage   | A   | 1/2/3   | 8088        | 개발 배포. 프로젝트별 독립 환경    |
| stage   | B   | 1/2/3   | 8089        | 개발 배포. 신규 배포 대기          |
| preview | A   | -       | 8088        | 프리뷰 배포. QA/검수용             |
| preview | B   | -       | 8089        | 프리뷰 배포. 신규 배포 대기        |

- **총 Set 수**: primary×2 + stage×6 + preview×2 = **10개 Set**
- 각 Set은 Apache(VirtualHost) + Tomcat(WAS) 컨테이너 쌍으로 구성
- **배포 원칙**: 현재 Set A(8088)가 운영 중 → Set B(8089)에 새 컨테이너 생성 → 검증 → NLB 포트 전환 → Set A 제거

### EC2 인스턴스 Tag 전략

```
Name:        price-{lane}-{stageNo}-{set}-{role}  (예: price-stage-2-B-web)
application: mo | pc
lane:        primary | stage | preview
stageNo:     1 | 2 | 3  (stage lane에서만 사용, 나머지는 "0")
set:         A | B
role:        web | was
```

**태그 활용 목적**: 배포 스크립트에서 AWS CLI로 대상 인스턴스를 동적으로 조회.
```bash
aws ec2 describe-instances \
  --filters "Name=tag:lane,Values=stage" \
            "Name=tag:stageNo,Values=2" \
            "Name=tag:set,Values=B" \
            "Name=tag:role,Values=was" \
  --query "Reservations[*].Instances[*].InstanceId" --output text
```

### CI/CD 파이프라인 (GitHub Actions)

```
Git Push / Workflow Dispatch (lane, stageNo, set, app 입력)
    │
    ▼
GitHub Actions Runner
    │
    ├── Job 1: build
    │     └── 앱 빌드 → Docker 이미지 빌드
    │
    ├── Job 2: push  (needs: build)
    │     └── ECR(Elastic Container Registry)에 이미지 Push
    │         태그: {lane}-{stageNo}-{set}-{git-sha}
    │
    └── Job 3: deploy  (needs: push)
          ├── AWS 인증 (OIDC — 장기 자격증명 없음)
          ├── EC2 Tag 조회 → 대상 인스턴스 ID 획득
          ├── SSM Run Command → EC2에서 docker pull + docker run
          ├── Health Check (curl /health 루프)
          ├── NLB 포트 전환 or ALB TG 전환
          └── 구 Set 컨테이너 제거
```

### 가격 데이터 파이프라인

```
RDS (가격 원천 DB)
    │  binlog CDC (row-based)
    ▼
AWS DMS (Database Migration Service)
    │  변경분 캡처 → Kafka produce
    ▼
Apache Kafka (KRaft 모드, Broker 3대)
    ├── Topic: price-events-setA  ← Set A Consumer만 구독
    └── Topic: price-events-setB  ← Set B Consumer만 구독
    │
    ▼
Kafka Consumer (WAS 내부 or 별도 서비스)
    │  set 구분값 파싱 → 분기 저장
    ▼
Redis
    ├── price:setA:productId:{id}  →  Hash { regular, sale, updatedAt }
    └── price:setB:productId:{id}  →  Hash { regular, sale, updatedAt }
```

**예약 가격 경로 (Cron)**:
```
Batch Scheduler (Cron)
    │  매 N분마다: SELECT * FROM prices WHERE scheduled_at <= NOW() AND applied = false
    ▼
Kafka produce → price-events-setA / price-events-setB
    ▼
Redis 갱신 → DB: applied = true
```

### 로그 수집 파이프라인 (ELK)

```
EC2 (Web/WAS 컨테이너 로그)
    │  Docker log driver → 파일 or stdout
    ▼
Filebeat (각 EC2에 설치, inode tracking)
    │  fields: lane, set, stageNo, role 주입
    ▼
Logstash (Grok 파싱 파이프라인)
    │  index: logs-{lane}-{set}-YYYY.MM.dd
    ▼
Elasticsearch (Inverted Index, Shard/Replica)
    ▼
Kibana (Set별, Lane별 로그 대시보드)
```

---

## Week 1: Linux/OS 기초 원리 + AWS 네트워킹 & 인프라

**이 주차의 목표**: 인프라의 모든 배포 패턴은 OS 위에서 동작한다. "하나의 EC2에 여러 앱을 다른 포트로 띄우는 것이 어떻게 가능한가"처럼, AWS 서비스 이전에 Linux/OS 수준의 원리를 먼저 이해하고 네트워크 구조를 직접 만든다.

### Part A: Linux / OS 기초 원리

> **왜 여기서 배우는가**: AWS의 EC2, 컨테이너, 배포 스크립트는 모두 Linux 위에서 동작한다.
> 포트 바인딩, 프로세스 격리, 서비스 관리 원리를 모르면 배포 구조가 왜 그렇게 설계됐는지 이해할 수 없다.

**TCP 포트 바인딩 원리**

```
EC2 (Linux Kernel)
│
│  네트워크 패킷이 들어올 때 커널이 목적지 포트를 보고
│  해당 포트를 바인딩한 프로세스의 소켓으로 전달
│
├── :8081  ──►  PID 1111 (App-1 JVM)   소켓 FD#7
├── :8082  ──►  PID 2222 (App-2 JVM)   소켓 FD#7
├── :8083  ──►  PID 3333 (App-3 JVM)   소켓 FD#7
└── :8088  ──►  PID 4444 (Apache)      소켓 FD#5, FD#6
    :8089  ──►  PID 4444 (Apache)      (같은 프로세스, 두 소켓)
```

- **소켓(Socket)**: 프로세스가 OS에 요청해서 얻는 네트워크 통신 창구. `IP:PORT` 조합으로 식별
- **포트 바인딩**: `bind()` 시스템 콜 → 커널에 "이 포트는 내 프로세스가 받겠다" 등록
- **포트 충돌**: 이미 바인딩된 포트에 다른 프로세스가 `bind()` 시도 → `Address already in use` 에러
- **파일 디스크립터(FD)**: 소켓, 파일, 파이프 모두 FD로 관리. `ulimit -n`으로 최대 FD 수 제한
- **LISTEN 상태 확인**: `ss -tlnp` 또는 `netstat -tlnp` 로 어떤 프로세스가 어떤 포트를 바인딩했는지 확인

**프로세스 격리와 공유 자원**

```
EC2 물리 자원
┌──────────────────────────────────────────────┐
│  CPU: 4 core   RAM: 8GB   Disk I/O: 공유     │
│                                              │
│  ┌─────────────┐  ┌─────────────┐           │
│  │ App-1 JVM   │  │ App-2 JVM   │           │
│  │ PID 1111    │  │ PID 2222    │           │
│  │ Heap: 2GB   │  │ Heap: 3GB   │           │
│  │ Port: 8081  │  │ Port: 8082  │           │
│  └─────────────┘  └─────────────┘           │
│                                              │
│  ⚠ Noisy Neighbor: App-2가 GC로 CPU 치솟으면  │
│    App-1도 응답 지연 발생                     │
└──────────────────────────────────────────────┘
```

- 프로세스는 독립된 메모리 공간(가상 주소 공간) → 서로 메모리 침범 불가
- CPU, 네트워크 대역폭, Disk I/O는 **공유** → 한 앱의 폭주가 다른 앱에 영향 (Noisy Neighbor)
- Docker 컨테이너: 동일한 커널 공유 + 네임스페이스(PID, NET, MNT)로 격리 → 같은 원리, 더 강한 격리

**systemd 서비스 관리**

```bash
# /etc/systemd/system/app1.service
[Unit]
Description=Price App 1
After=network.target

[Service]
User=app
WorkingDirectory=/opt/apps/app1
ExecStart=/usr/bin/java -jar app1.jar --server.port=8081
Restart=on-failure        # 프로세스 죽으면 자동 재시작
RestartSec=5

[Install]
WantedBy=multi-user.target
```

- `systemctl start/stop/restart app1`: 프로세스 시작/종료/재시작
- `systemctl status app1`: 프로세스 상태, 최근 로그 확인
- `journalctl -u app1 -f`: 실시간 로그 스트리밍
- `Restart=on-failure`: EC2가 살아있어도 JVM이 죽으면 자동 재시작 → 단순한 고가용성 확보
- **왜 중요한가**: 배포 스크립트에서 `systemctl restart app2`로 **특정 앱만** 재시작 → 나머지 앱 무중단

**이 원리가 배포에 연결되는 지점**

```
zip 배포 패턴에서:
  1. app2.zip → /opt/apps/app2/ 에 압축 해제 (파일 교체)
  2. systemctl restart app2          (프로세스 재시작, :8082 재바인딩)
  3. ALB TG-app2 Health Check 대기   (새 프로세스가 :8082 Listen 확인)
  4. TG-app2 트래픽 전환              (ALB가 새 프로세스로 라우팅)

  → app1(:8081), app3(:8083)은 전혀 영향받지 않음
    Linux 포트 바인딩 독립성 덕분에 가능
```

### Part B: AWS 네트워킹 & 인프라

- **VPC 내부 동작 원리**: CIDR 블록 설계, Subnet(Public/Private), Route Table, Internet Gateway, NAT Gateway
- **Security Group vs NACL**: Stateful(SG) vs Stateless(NACL) 방화벽 차이 — 왜 두 개가 공존하는가
- **IAM Role**: EC2 인스턴스 프로파일, Policy 구조 (어떻게 권한이 EC2 내부 프로세스까지 전파되는가)
- **EC2**: AMI, Launch Template, User Data 스크립트 (첫 부팅 시 자동 설정)
- **NLB vs ALB**: L4(NLB)와 L7(ALB)의 차이
  - NLB: 고정 IP, 극저지연, 포트 기반 라우팅 → 8088/8089 듀얼 포트 운용에 적합
  - ALB: HTTP 헤더/Path 인식 → Set A/B WAS 분기 라우팅에 적합
- **ECR (Elastic Container Registry)**: Docker 이미지를 AWS에 저장하는 원리, IAM Role 기반 pull 인증

### 핵심 질문 (주말까지 스스로 답할 수 있어야 함)

1. 하나의 EC2에서 Apache가 8088과 8089를 동시에 Listen할 수 있는 OS 레벨 원리는?
2. App-1(:8081)이 OOM으로 죽었을 때 App-2(:8082)는 왜 영향받지 않는가? 무엇이 영향받는가?
3. `systemctl restart app2`로 배포할 때 app1 트래픽이 끊기지 않는 이유는?
4. Private Subnet의 EC2가 ECR에서 이미지를 pull하는 경로는? (NAT Gateway vs VPC Endpoint)
5. Security Group은 왜 "Stateful"인가? (응답 트래픽에 별도 규칙이 없어도 되는 이유)

### 실습

- `ss -tlnp` 로 현재 EC2에서 바인딩된 포트 확인
- 간단한 Python HTTP 서버를 두 포트로 띄우기: `python3 -m http.server 8081 &` + `8082 &`
  → 두 프로세스가 독립적으로 응답하는 것 확인 → 하나 죽여도 나머지 살아있음 확인
- systemd unit 파일 직접 작성 + `Restart=on-failure` 검증 (kill -9 후 자동 재시작 확인)
- VPC 직접 설계: Public Subnet (NLB, Bastion), Private Subnet (Web, WAS, Redis, RDS)
- EC2 Launch Template 생성 — tag 포함: `application=mo, lane=primary, stageNo=0, set=A, role=web`
- ECR 리포지토리 생성 + IAM Role (EC2 → ECR pull 권한) 연결
- Security Group 설계: NLB(8088/8089) → Web 허용, Web → ALB 허용, ALB → WAS(8080) 허용

---

## Week 2: Docker + Apache/Tomcat 로컬 Blue-Green 실습

**이 주차의 목표**: AWS를 쓰기 전에 Docker Compose로 Apache 멀티포트 + Tomcat Set A/B 구조를 로컬에서 완전히 재현하고, Immutable 배포와 Blue-Green 전환 원리를 직접 체험한다.

### 핵심 개념

**Docker 원리**
- **이미지 레이어 구조**: Dockerfile 명령어 하나 = 레이어 하나. 레이어 캐시가 빌드 속도에 미치는 영향
- **컨테이너 vs VM**: 커널 공유, 네임스페이스(PID/NET/MNT) 격리 원리
- **Docker 네트워크**: bridge(기본), host, overlay — 컨테이너 간 통신 방식
- **Docker 볼륨**: 컨테이너 재시작 후에도 데이터가 살아있는 이유

**Immutable Deployment (불변 배포)**
- **핵심 철학**: 기존 컨테이너를 수정(mutable)하지 않음 → 새 이미지 빌드 → 새 컨테이너 기동 → 트래픽 전환 → 구 컨테이너 제거
- **왜 Immutable인가**: 환경 드리프트(설정이 서버마다 달라지는 현상) 방지, 롤백이 이미지 태그 교체로 단순화
- **vs Mutable**: 기존 EC2에 SSH 접속해서 파일 교체 → 문제: 재현 불가, 롤백 복잡

**Apache 멀티포트 VirtualHost**
- `Listen` 지시어로 복수 포트 바인딩
- `<VirtualHost *:PORT>` 블록으로 포트별 독립 동작 설정
- Apache → Tomcat 연결: `mod_proxy` + `ProxyPass` (HTTP 리버스 프록시)

**Docker Compose Blue-Green 전환 흐름**
```
[현재 상태]
apache:8088 → tomcat-setA:8080  (운영 중)
apache:8089 → tomcat-setB:8080  (미사용 or 구버전)

[배포 시작: Set B에 새 버전 배포]
1. docker build → new-image:v2
2. docker compose up -d tomcat-setB  (새 컨테이너 기동, 8089는 아직 미연결)
3. Health Check: curl http://localhost:8089/health
4. Apache conf 수정: 8089 → tomcat-setB (새 컨테이너)
5. apache reload (무중단 — graceful reload)
6. 검증 후 tomcat-setA 컨테이너 제거
```

### Docker Compose 실습 구성

```yaml
# docker-compose.yml
services:
  apache:
    image: httpd:2.4
    ports:
      - "8088:8088"
      - "8089:8089"
    volumes:
      - ./conf/httpd.conf:/usr/local/apache2/conf/httpd.conf:ro
    depends_on:
      - tomcat-setA
      - tomcat-setB
    networks:
      - app-net

  tomcat-setA:
    image: my-app:v1          # Set A = 현재 운영 버전
    container_name: tomcat-setA
    environment:
      - SET=A
    networks:
      - app-net

  tomcat-setB:
    image: my-app:v2          # Set B = 신규 배포 버전
    container_name: tomcat-setB
    environment:
      - SET=B
    networks:
      - app-net

networks:
  app-net:
    driver: bridge
```

**Dockerfile 작성 포인트**:
```dockerfile
FROM tomcat:10-jre17-temurin   # 최신 LTS 기준
WORKDIR /usr/local/tomcat/webapps
COPY target/app.war ROOT.war
# 레이어 캐시 최적화: 변경 빈도 낮은 것 먼저
EXPOSE 8080
HEALTHCHECK --interval=10s --timeout=3s \
  CMD curl -f http://localhost:8080/health || exit 1
```

### 핵심 질문

1. `docker compose up -d tomcat-setB` 실행 시 기존 tomcat-setA는 영향받지 않는 이유는?
2. Apache `graceful reload`와 일반 `restart`의 차이는? (왜 reload가 무중단인가)
3. Immutable 배포에서 롤백이 단순한 이유는? (이미지 태그 관점)
4. 컨테이너가 죽었다 재시작될 때 내부 파일(로그 등)이 사라지는 이유는? (레이어 원리)

### 실습 시나리오

1. `docker-compose.yml` + `httpd.conf` 작성 → `docker compose up`
2. `curl http://localhost:8088/health` (Set A 응답 확인)
3. Set B용 새 이미지 빌드 (`my-app:v2`) → tomcat-setB 컨테이너 교체
4. Apache conf에서 8089 → 새 컨테이너 연결 → `docker exec apache httpd -k graceful`
5. 8088/8089 동시 요청하며 전환 전/후 응답 버전 직접 확인
6. 구 tomcat-setA 컨테이너 제거 (`docker compose rm -s tomcat-setA`)

---

## Week 3: NLB + ALB + ASG — AWS 환경 Blue-Green 무중단 배포

**이 주차의 목표**: Week 2에서 로컬로 체험한 Blue-Green 구조를 AWS 인프라로 옮긴다. NLB 듀얼 포트 + ASG Immutable 배포 원리를 이해하고, 배포 스크립트의 뼈대를 작성한다.

### 핵심 개념

**NLB 듀얼 포트 구조**
- NLB Listener 8088 → Target Group Web-SetA (Apache EC2 포트 8088)
- NLB Listener 8089 → Target Group Web-SetB (Apache EC2 포트 8089)
- 포트 전환 = NLB Listener의 Target Group 교체 (트래픽이 즉시 새 TG로 이동)

**ALB + Target Group**
- ALB는 WAS(Tomcat) 레벨에서 Set A/B 분기
- Target Group SetA → WAS Set A EC2 (또는 컨테이너 포트)
- Target Group SetB → WAS Set B EC2
- **Health Check**: `/health` 경로, 2회 연속 성공 시 InService 등록

**ASG Immutable Deployment**
- Launch Template에 User Data 스크립트 포함:
  ```bash
  #!/bin/bash
  # ECR에서 최신 이미지 Pull
  aws ecr get-login-password | docker login --username AWS --password-stdin {ECR_URI}
  docker pull {ECR_URI}/price-app:{IMAGE_TAG}
  docker run -d -p 8080:8080 \
    -e SET=${SET} -e LANE=${LANE} \
    --name tomcat-${SET} \
    {ECR_URI}/price-app:{IMAGE_TAG}
  ```
- 배포 시 새 Launch Template 버전 생성 → ASG Instance Refresh → 새 EC2 기동 → 구 EC2 제거
- **Instance Refresh**: 한 번에 교체 비율 지정 (예: 50% → 나머지 50% 순서로 교체)

**Connection Draining (Deregistration Delay)**
- TG에서 인스턴스 제거 시 즉시 끊지 않음
- 기존 연결 처리 완료 대기 (기본 300초) → 완료 후 제거
- 왜 필요한가: 사용자가 요청 중인 상태에서 인스턴스가 갑자기 내려가면 에러 발생

### 배포 스크립트 흐름 (Bash)

```bash
#!/bin/bash
# deploy.sh --lane primary --set B --stageNo 0 --app mo --image-tag v1.2.3

# 1. 파라미터 파싱
# 2. 대상 EC2 조회 (Tag 기반)
INSTANCE_IDS=$(aws ec2 describe-instances \
  --filters "Name=tag:lane,Values=${LANE}" \
            "Name=tag:stageNo,Values=${STAGE_NO}" \
            "Name=tag:set,Values=${SET}" \
            "Name=tag:role,Values=was" \
  --query "Reservations[*].Instances[?State.Name=='running'].InstanceId" \
  --output text)

# 3. SSM Run Command로 새 컨테이너 기동
aws ssm send-command \
  --instance-ids ${INSTANCE_IDS} \
  --document-name "AWS-RunShellScript" \
  --parameters "commands=[
    'docker pull ${ECR_URI}:${IMAGE_TAG}',
    'docker stop tomcat-${SET} || true',
    'docker rm tomcat-${SET} || true',
    'docker run -d -p 8080:8080 --name tomcat-${SET} ${ECR_URI}:${IMAGE_TAG}'
  ]"

# 4. Health Check (ALB TG 상태 대기)
wait_for_healthy() {
  for i in $(seq 1 30); do
    STATUS=$(aws elbv2 describe-target-health \
      --target-group-arn ${TG_ARN} \
      --query "TargetHealthDescriptions[*].TargetHealth.State" \
      --output text)
    [[ "$STATUS" == "healthy" ]] && return 0
    sleep 10
  done
  return 1
}

# 5. NLB 포트 전환 (8088 ↔ 8089)
aws elbv2 modify-listener \
  --listener-arn ${NLB_LISTENER_ARN} \
  --default-actions Type=forward,TargetGroupArn=${NEW_TG_ARN}
```

### 멀티앱 단일 EC2 패턴 (Zip 배포 방식)

> **실무에서 자주 만나는 패턴**: 비용 절감을 위해 여러 앱을 하나의 EC2에 올리고,
> 각각 다른 포트로 띄운 뒤 ALB에서 포트별 TG로 분리하는 구조.
> Week 1에서 배운 Linux TCP 포트 바인딩 원리가 이 패턴의 기반.

**[ 배포 파이프라인: S3 Zip 아티팩트 방식 ]**

```
소스 디렉토리 구조
┌─────────────────────────┐
│  /apps                  │
│   ├── app1/             │
│   ├── app2/             │
│   └── app3/             │
└────────────┬────────────┘
             │ 빌드 (maven/gradle)
             ▼
┌─────────────────────────────────────────────────────┐
│  GitHub Actions                                     │
│                                                     │
│  ├── app1/ → app1-{git-sha}.zip                    │
│  ├── app2/ → app2-{git-sha}.zip                    │
│  └── app3/ → app3-{git-sha}.zip                    │
│              │                                      │
│              ▼ S3 Upload                            │
│  s3://bucket/{lane}/{stageNo}/{set}/                │
│    ├── app1/{git-sha}/app1.zip                     │
│    ├── app2/{git-sha}/app2.zip                     │
│    └── app3/{git-sha}/app3.zip                     │
└───────────────────────┬─────────────────────────────┘
                        │ SSM Run Command
                        │ (EC2 Tag로 대상 특정)
                        ▼
```

**[ EC2 내부 구조: 멀티앱 + 포트 분리 ]**

```
┌──────────────────────────────────────────────────────────┐
│  EC2  (tag: lane=primary, set=B, role=was)               │
│                                                          │
│  /opt/apps/                                              │
│    ├── app1/  ←── app1.zip 압축해제                     │
│    │     ├── app1.jar                                    │
│    │     └── config/application.yml                      │
│    │     [systemd: app1.service]                         │
│    │      └── java -jar app1.jar --port=8081  ─► :8081  │
│    │                                                      │
│    ├── app2/  ←── app2.zip 압축해제                     │
│    │     [systemd: app2.service]                         │
│    │      └── java -jar app2.jar --port=8082  ─► :8082  │
│    │                                                      │
│    └── app3/  ←── app3.zip 압축해제                     │
│          [systemd: app3.service]                         │
│           └── java -jar app3.jar --port=8083  ─► :8083  │
│                                                          │
│  Linux Kernel TCP Stack                                  │
│    inbound :8081 ──► app1 프로세스 소켓 (PID 1111)      │
│    inbound :8082 ──► app2 프로세스 소켓 (PID 2222)      │
│    inbound :8083 ──► app3 프로세스 소켓 (PID 3333)      │
└──────────┬──────────────┬──────────────┬─────────────────┘
           │ :8081         │ :8082         │ :8083
           │               │               │
```

**[ ALB 라우팅 구조: TG 포트 오버라이드 ]**

```
           │ :8081         │ :8082         │ :8083
           │               │               │
┌──────────▼───────────────▼───────────────▼──────────────┐
│  ALB (Internal)                                         │
│                                                         │
│  Listener :80                                           │
│    ├── Rule: Path /app1/*  ──────────────► TG-app1     │
│    ├── Rule: Path /app2/*  ──────────────► TG-app2     │
│    └── Rule: Path /app3/*  ──────────────► TG-app3     │
│                                                         │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐    │
│  │  TG-app1    │  │  TG-app2    │  │  TG-app3    │    │
│  │             │  │             │  │             │    │
│  │  등록 대상: │  │  등록 대상: │  │  등록 대상: │    │
│  │  EC2:8081   │  │  EC2:8082   │  │  EC2:8083   │    │
│  │  ↑ 포트     │  │  ↑ 포트     │  │  ↑ 포트     │    │
│  │  오버라이드 │  │  오버라이드 │  │  오버라이드 │    │
│  │             │  │             │  │             │    │
│  │ HealthCheck │  │ HealthCheck │  │ HealthCheck │    │
│  │ GET :8081   │  │ GET :8082   │  │ GET :8083   │    │
│  │ /health     │  │ /health     │  │ /health     │    │
│  └─────────────┘  └─────────────┘  └─────────────┘    │
└─────────────────────────────────────────────────────────┘

  핵심: 같은 EC2 인스턴스가 3개 TG에 서로 다른 포트로 등록됨
  → ALB Target Group은 인스턴스 등록 시 포트를 개별 지정 가능 (포트 오버라이드)
```

**app2만 배포할 때의 무중단 흐름**:
```bash
# 1. TG-app2에서 해당 EC2 Deregister (Draining 시작, app1/app3 영향 없음)
aws elbv2 deregister-targets --target-group-arn {TG-app2} \
  --targets Id={EC2-ID},Port=8082

# 2. app2만 배포 (app1:8081, app3:8083은 운영 중)
aws s3 cp s3://bucket/primary/0/B/app2/{git-sha}/app2.zip /opt/apps/app2/
unzip -o app2.zip -d /opt/apps/app2/
systemctl restart app2

# 3. Health Check 후 TG-app2 다시 Register
aws elbv2 register-targets --target-group-arn {TG-app2} \
  --targets Id={EC2-ID},Port=8082
```

**이 패턴의 트레이드오프**:

| 관점 | 멀티앱 단일 EC2 | 앱당 개별 EC2/컨테이너 |
|------|-----------------|------------------------|
| 비용 | 저렴 (EC2 1대) | 비쌈 |
| 프로세스 격리 | 부분적 (JVM 분리, 커널·자원 공유) | 완전 격리 |
| Noisy Neighbor | 발생 가능 (메모리/CPU 경합) | 없음 |
| 배포 단위 | 앱별 zip 독립 배포 | 이미지 단위 |
| OOM 장애 전파 | 전체 EC2 영향 가능 | 해당 컨테이너만 |

### 핵심 질문

1. ASG Instance Refresh 중에 트래픽이 끊기지 않는 이유는? (Desired 수와 교체 비율의 관계)
2. NLB Listener의 Target Group을 교체하면 기존 연결은 어떻게 되는가?
3. User Data 스크립트가 실패하면 EC2는 어떤 상태가 되는가? (Health Check와의 관계)
4. `docker stop` vs `docker kill` 차이는? 무중단 배포에서 어느 쪽을 써야 하는가?
5. ALB Target Group에서 동일한 EC2를 8081/8082/8083으로 각각 다른 TG에 등록하는 방법은?

### 실습

- NLB 8088/8089 듀얼 Listener 구성 → Apache EC2 연결
- ALB Target Group SetA / SetB 생성 + Health Check 설정
- **멀티앱 EC2 실습**: 하나의 EC2에 Spring Boot 앱 2개를 8081/8082 포트로 띄우고 ALB TG 2개에 포트 오버라이드 등록
- ASG Launch Template에 User Data(ECR pull + docker run) 작성
- deploy.sh 스크립트 작성 + 수동 실행으로 Set B 배포 → NLB 전환 → Set A 제거
- Deregistration Delay를 30초로 줄이고 전환 중 요청 로그 관찰

---

## Week 4: GitHub Actions CI/CD 파이프라인 + Tag 기반 배포 자동화

**이 주차의 목표**: Week 3의 수동 배포 스크립트를 GitHub Actions 워크플로우로 자동화한다. OIDC 인증, Job 순서 제어, 배포 파라미터 관리 원리를 이해한다.

### 핵심 개념

**GitHub Actions 구조**
```
Workflow (.github/workflows/deploy.yml)
  └── on: (트리거: push, workflow_dispatch, schedule)
       └── jobs:
             ├── build      (Runner에서 실행되는 독립 VM)
             │     └── steps: (순차 실행)
             │           ├── uses: actions/checkout@v4
             │           ├── run: mvn package
             │           └── run: docker build
             ├── push       (needs: build → 순서 보장)
             │     └── steps: ECR 로그인 → docker push
             └── deploy     (needs: push)
                   └── steps: AWS 인증 → EC2 태그 조회 → SSM 배포 → Health Check → TG 전환
```

**OIDC 인증 (최신 트렌드, 실무 권장)**
- 기존 방식 (Bad): AWS Access Key/Secret을 GitHub Secrets에 저장 → 장기 자격증명 노출 위험
- OIDC 방식 (Good): GitHub Actions Runner가 AWS에 JWT 토큰 제시 → AWS STS가 임시 자격증명 발급
  - 토큰 수명: 1시간 (워크플로우 실행 동안만 유효)
  - GitHub Secrets에 저장하는 것: AWS Account ID + IAM Role ARN (키 없음)

```yaml
# OIDC 설정 예시
- uses: aws-actions/configure-aws-credentials@v4
  with:
    role-to-assume: arn:aws:iam::123456789:role/github-deploy-role
    aws-region: ap-northeast-2
    # Access Key 없음 — OIDC 토큰으로 자동 인증
```

**워크플로우 설계 원칙**
- **Job 분리 이유**: build 실패 시 push/deploy가 실행되지 않도록 의존성 명시 (`needs`)
- **Concurrency**: 같은 lane/set에 동시 배포 방지 (이전 배포가 끝나기 전 새 배포 시작 차단)
- **Environment**: GitHub Environments로 primary 배포는 승인(Approve) 필요 설정 가능
- **Artifact**: build Job에서 생성한 파일(Docker 이미지 정보)을 deploy Job으로 전달

**ECR 이미지 태깅 전략**
```
{ECR_URI}/price-app:{lane}-{stageNo}-{set}-{git-sha}
예: 123.dkr.ecr.../price-app:primary-0-B-a1b2c3d
```
- git-sha 포함: 어느 커밋이 배포됐는지 추적 가능
- lane/set 포함: 이미지가 어느 환경용인지 명시

### 실제 워크플로우 구조

```yaml
name: Blue-Green Deploy

on:
  workflow_dispatch:
    inputs:
      lane:
        type: choice
        options: [primary, stage, preview]
        required: true
      stageNo:
        type: choice
        options: ['0', '1', '2', '3']
        default: '0'
      set:
        type: choice
        options: [A, B]
        required: true
      app:
        type: choice
        options: [mo, pc]
        required: true

concurrency:
  group: deploy-${{ inputs.lane }}-${{ inputs.stageNo }}-${{ inputs.set }}
  cancel-in-progress: false  # 진행 중 배포는 취소하지 않음

jobs:
  build:
    runs-on: ubuntu-latest
    outputs:
      image-tag: ${{ steps.tag.outputs.tag }}
    steps:
      - uses: actions/checkout@v4
      - name: Set image tag
        id: tag
        run: echo "tag=${{ inputs.lane }}-${{ inputs.stageNo }}-${{ inputs.set }}-${GITHUB_SHA::7}" >> $GITHUB_OUTPUT
      - name: Build Docker image
        run: docker build -t price-app:${{ steps.tag.outputs.tag }} .

  push:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ap-northeast-2
      - name: Push to ECR
        run: |
          aws ecr get-login-password | docker login --username AWS --password-stdin $ECR_URI
          docker push $ECR_URI/price-app:${{ needs.build.outputs.image-tag }}

  deploy:
    needs: [build, push]
    runs-on: ubuntu-latest
    environment: ${{ inputs.lane == 'primary' && 'production' || 'development' }}
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_DEPLOY_ROLE_ARN }}
          aws-region: ap-northeast-2
      - name: Get EC2 by tag & deploy via SSM
        run: ./scripts/deploy.sh
          --lane ${{ inputs.lane }}
          --stageNo ${{ inputs.stageNo }}
          --set ${{ inputs.set }}
          --image-tag ${{ needs.build.outputs.image-tag }}
      - name: Health check & traffic switch
        run: ./scripts/switch-traffic.sh --set ${{ inputs.set }}
```

### 핵심 질문

1. OIDC 방식에서 AWS가 GitHub Actions Runner를 신뢰하는 원리는? (IdP, JWT, STS의 역할)
2. `needs: [build, push]` 설정이 없으면 어떤 문제가 생기는가?
3. `concurrency.cancel-in-progress: false`로 설정한 이유는? (배포 도중 취소 시 발생하는 문제)
4. GitHub Environments의 `required reviewers` 기능은 언제 사용하는가?

### 실습

- IAM Role에 GitHub OIDC Provider 신뢰 정책 추가
- `.github/workflows/deploy.yml` 작성 (위 구조 기반)
- `workflow_dispatch`로 수동 트리거 → Jobs 순서 및 로그 확인
- `concurrency` 설정 테스트: 두 번 연속 트리거 → 두 번째가 대기하는 동작 확인
- primary lane 배포 시 GitHub Environment 승인 화면 동작 확인

---

## Week 5: Apache Kafka 핵심 원리 + AWS DMS CDC

**이 주차의 목표**: Kafka의 내부 동작 원리(Partition, Offset, Rebalancing)를 직접 실험으로 확인하고, DMS를 통한 CDC 파이프라인을 구성한다.

### 핵심 개념

- **Kafka 아키텍처**: Broker, KRaft(ZooKeeper 대체, Kafka 3.x 이상 최신), Topic, Partition, Offset, Segment
- **Producer**: Partitioner 전략 (key hash → 같은 상품은 같은 Partition에 순서 보장), acks 설정
  - `acks=0`: fire-and-forget (유실 가능)
  - `acks=1`: Leader 확인 (일반적)
  - `acks=all`: ISR 전체 확인 (가격 적재처럼 중요한 데이터에 적합)
- **Consumer Group**: Partition 할당 원리, Rebalancing (Consumer 추가/제거 시 재할당), Offset Commit
  - **at-least-once**: Redis HSET은 멱등(같은 값으로 덮어써도 결과 동일) → 중복 처리 허용 가능
- **Set 기반 토픽 분리 전략**:
  ```
  price-events-setA   ← Set A WAS Consumer만 구독
  price-events-setB   ← Set B WAS Consumer만 구독
  price-events-all    ← 감사/모니터링용 (모든 이벤트)
  ```
- **AWS DMS CDC (Change Data Capture)**:
  - RDS MySQL `binlog_format=ROW` 필수 설정
  - DMS Replication Instance → Source Endpoint(RDS) → Target Endpoint(Kafka MSK)
  - 변환 메시지 구조: `{ "op": "U", "before": {...}, "after": {...}, "ts_ms": 1700000000 }`
- **Cron + Kafka 패턴**: 예약 가격은 DMS가 감지 못함 (scheduled_at이 미래) → Batch가 직접 produce

### 핵심 질문

1. Partition 수와 Consumer 수의 관계는? Consumer 수 > Partition 수이면 어떻게 되는가?
2. Consumer가 죽었다 재시작하면 어디서부터 읽는가? (`auto.offset.reset` 옵션)
3. DMS는 RDS binlog의 어떤 이벤트를 어떻게 Kafka 메시지 구조로 변환하는가?
4. **배포 중 Kafka Consumer를 멈춰야 하는 이유**: 구버전 Consumer(Set A)와 신버전 Consumer(Set B)가 동시에 같은 토픽을 consume하면 가격 불일치가 발생하는 시나리오를 설명하라

### 실습

```yaml
# docker-compose.yml (로컬 Kafka 클러스터)
services:
  kafka-1:
    image: apache/kafka:3.7.0   # KRaft 모드 (ZooKeeper 불필요)
    environment:
      KAFKA_NODE_ID: 1
      KAFKA_PROCESS_ROLES: broker,controller
  kafka-2: ...
  kafka-3: ...
  kafka-ui:
    image: provectuslabs/kafka-ui   # 토픽/Consumer 상태 시각화
```

- `price-events-setA` / `price-events-setB` 토픽 생성 (partition=3, replication-factor=2)
- Python Producer: RDS 가격 변경 데이터 → Kafka produce (set 구분값 포함)
- Consumer Group 실험: Consumer 추가/제거 → kafka-ui에서 Rebalancing 직접 관찰
- AWS DMS 설정: RDS MySQL binlog → Kafka 메시지 구조 확인

---

## Week 6: Redis 캐시 전략 + ELK 스택

**이 주차의 목표**: Redis에 Set A/B 가격을 분리 저장하는 전략을 완성하고, Filebeat → Logstash → Kibana 전체 로그 파이프라인을 구성한다.

### Part A: Redis 캐시 전략

**핵심 개념**

- **Redis 데이터 구조 선택**:
  - `Hash`: `price:setA:123` → `{ regular: 10000, sale: 8000, updatedAt: ... }` → 필드별 접근/갱신 → **가격 캐시에 적합**
  - `String`: JSON blob → 단순하지만 부분 업데이트 불가
  - `Sorted Set`: 가격순 정렬 필요 시 (랭킹, 범위 조회)
- **Set A/B 분리 저장 구조**:
  ```
  HSET price:setA:productId:123  regular 10000  sale 8000  updatedAt 1700000000
  HSET price:setB:productId:123  regular 10000  sale 7500  updatedAt 1700000001
  ```
- **Kafka Consumer → Redis 적재 흐름**:
  ```
  메시지 수신 → set 구분값 파싱 → price:setA or price:setB 키 결정
  → HSET 저장 → Offset Commit (저장 성공 후 커밋 → at-least-once 보장)
  ```
- **Redis Cluster vs Sentinel**: Cluster(수평 샤딩) vs Sentinel(단일 마스터 장애조치)
- **예약 가격**: `scheduled_at <= NOW() AND applied = false` → produce → Redis 갱신 → `applied = true`

**핵심 질문**

1. Redis HSET과 SET(String)의 메모리 사용량 차이는?
2. Kafka에서 Redis 저장 실패 시 Offset Commit을 어떻게 처리해야 하는가?
3. 가격이 연속 변경될 때 Redis 갱신 순서(Ordering) 보장: 상품 ID를 Partition key로 쓰는 이유는?

### Part B: ELK 스택 — 로그 수집 & 모니터링

**핵심 개념**

- **Filebeat 동작 원리**: inode + offset 기반 파일 추적 (rotate 후에도 새 파일 자동 감지)
- **Log Rotation 원리**: `logrotate` → 파일 rename → 새 파일 생성 → Filebeat inode 변경 감지
- **Docker 로그 수집**: 컨테이너 stdout → Docker log driver(json-file) → 파일 → Filebeat
- **Logstash 파이프라인**:
  ```
  input  { beats { port => 5044 } }
  filter {
    grok { match => { "message" => "%{COMBINEDAPACHELOG}" } }
    # lane, set, stageNo는 Filebeat fields로 주입
  }
  output {
    elasticsearch {
      hosts => ["es:9200"]
      index => "logs-%{[fields][lane]}-%{[fields][set]}-%{+YYYY.MM.dd}"
    }
  }
  ```
- **Filebeat fields 활용**: 각 EC2의 Filebeat 설정에 해당 인스턴스 tag 정보 주입
  ```yaml
  fields:
    lane: stage
    stageNo: "2"
    set: B
    role: web
  fields_under_root: true
  ```
- **Elasticsearch 인덱싱**: Inverted Index, Shard(분산)/Replica(복제), Index Template (자동 매핑)
- **Kibana KQL**:
  ```
  lane: "stage" AND set: "B" AND stageNo: "2"
  ```

**핵심 질문**

1. Filebeat는 파일이 rotate 됐을 때 어떻게 새 파일을 감지하는가? (inode 변경 원리)
2. Logstash Grok 파싱 실패 시 해당 로그는 어떻게 처리되는가? (`_grokparsefailure` 태그)
3. Elasticsearch Shard 수를 나중에 변경할 수 없는 이유는?
4. Docker 컨테이너가 재시작될 때 로그 파일이 사라지면 Filebeat는 어떻게 되는가?

**실습**

```yaml
# docker-compose.yml (ELK 스택)
services:
  elasticsearch:
    image: elasticsearch:8.13.0
  logstash:
    image: logstash:8.13.0
  kibana:
    image: kibana:8.13.0
  filebeat:
    image: elastic/filebeat:8.13.0
    volumes:
      - /var/log:/var/log:ro        # 호스트 로그 마운트
      - ./filebeat.yml:/filebeat.yml
```

- WAS/Apache 로그 샘플 생성 → Filebeat → Logstash Grok → Elasticsearch 흐름 확인
- Kibana에서 Set별, Lane별 로그 대시보드 (Bar chart: 시간대별 요청수 per set)
- `logrotate -f` 강제 rotate → Filebeat 재감지 확인

---

## Week 7 (구현 주간): 통합 비즈니스 구현

6주간 학습한 기술을 조합하여 상품가격 적재 프로세스 전체를 실제로 동작시킨다:

| 단계 | 내용 | 관련 주차 |
|------|------|-----------|
| 1 | VPC + Subnet + Security Group 설계 | Week 1 |
| 2 | ECR 리포지토리 + IAM Role (OIDC) 구성 | Week 1, 4 |
| 3 | Docker Compose로 전체 스택 로컬 검증 | Week 2 |
| 4 | NLB(8088/8089) + Apache VirtualHost + ALB + WAS 구성 | Week 3 |
| 5 | GitHub Actions 워크플로우 작성 → Set B 배포 → TG 전환 | Week 4 |
| 6 | RDS + DMS + Kafka 가격 변경 파이프라인 | Week 5 |
| 7 | Cron 기반 예약 가격 이벤트 처리 | Week 5 |
| 8 | Kafka Consumer → Redis (Set A/B 분리 저장) | Week 6 |
| 9 | Filebeat + ELK 스택 연동 → Kibana 대시보드 | Week 6 |
| 10 | 장애 시나리오: Consumer 다운, Health Check 실패, Log Rotate, 포트 전환 중 요청 관찰 | 전체 |

---

## 브랜치 전략 (GitHub Repository)

```
main                  ← 최종 통합 결과물 (Week 7 완성본)
  │
  ├── week1/vpc-networking
  ├── week2/docker-bluegreen-local
  ├── week3/alb-asg-bluegreen-aws
  ├── week4/github-actions-cicd
  ├── week5/kafka-dms-pipeline
  └── week6/redis-elk-stack
```

각 브랜치에는 해당 주차에서 작성한 코드, 설정 파일, 학습 메모를 커밋.
주차 완료 후 main에 PR → 머지.

---

## 학습 원칙

| 원칙 | 내용 |
|------|------|
| **원리 우선** | 왜 이 기술이 존재하는가 → 어떻게 동작하는가 → 어떻게 쓰는가 순서로 접근 |
| **다이어그램 우선** | 새로운 개념을 만나면 설명보다 그림을 먼저 요청/그리기. 아래 지침 참고 |
| **로컬 우선** | Kafka, ELK, Docker Blue-Green은 로컬 Docker Compose로 먼저 → 원리 이해 후 AWS 이관 |
| **직접 깨기** | 의도적으로 장애 상황(Consumer 죽이기, Health Check 실패, rotate 등)을 만들어 복구 흐름 관찰 |
| **비용 주의** | 실습 후 리소스 즉시 삭제 (NAT Gateway, ALB, ElastiCache, DMS — Free Tier 미적용) |
| **기록** | 주차별 "무엇을 몰랐고, 어떻게 이해했는가" 브랜치에 커밋 |

---

## 다이어그램 학습 지침

> 텍스트 설명만으로 이해하기 어려운 인프라 개념은 **다이어그램을 먼저 그리고 나서** 설명을 붙이는 방식으로 접근한다.
> "배포 파이프라인 → EC2 내부 구조 → ALB 라우팅" 같은 레이어 분리 다이어그램이 이해에 결정적으로 도움이 된다.

### 다이어그램을 그려야 할 상황

- **요청 흐름이 여러 컴포넌트를 거칠 때**: Client → 방화벽 → NLB → Apache → ALB → WAS
- **하나의 컴포넌트 내부 구조가 궁금할 때**: EC2 안에서 포트/프로세스/파일이 어떻게 배치되는가
- **데이터가 변환/이동하는 파이프라인**: RDS → DMS → Kafka → Consumer → Redis
- **배포 전/후 상태 변화**: Blue(운영) → Green(배포) → 전환 → Blue 제거
- **장애 시나리오**: Consumer 다운 시 메시지는 어디에 쌓이고, 재시작 후 어디서부터 읽는가

### 다이어그램의 레이어 분리 원칙

복잡한 구조는 하나의 큰 그림보다 **레이어별로 나누어** 그리는 것이 효과적:

```
레이어 1: 전체 흐름 (Big Picture)
  → 어떤 컴포넌트들이 어떤 순서로 연결되는가

레이어 2: 특정 컴포넌트 내부 (Zoom In)
  → 그 컴포넌트 안에서 무슨 일이 일어나는가

레이어 3: 데이터/상태 변화 (Before/After)
  → 배포 전, 배포 중, 배포 후 상태가 어떻게 바뀌는가
```

예시: Week 3 멀티앱 EC2 패턴을 배울 때
```
레이어 1: [S3] → [SSM] → [EC2] → [ALB] → [Client]
레이어 2: EC2 내부 = /opt/apps/app1(:8081) + app2(:8082) + app3(:8083)
레이어 3: app2 배포 = TG Deregister → zip 교체 → restart → HealthCheck → Register
```

### Claude에게 다이어그램 요청하는 방법

학습 중 개념이 잘 안 잡힐 때는 다음과 같이 요청:
- `"이 구조를 레이어별 ASCII 다이어그램으로 그려줘"`
- `"배포 전/후 상태를 Before/After 다이어그램으로 보여줘"`
- `"EC2 내부에서 포트와 프로세스 관계를 그려줘"`
- `"데이터가 흐르는 경로를 화살표로 표현해줘"`
