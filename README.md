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

## Week 1: Linux/OS 기초 원리 + AWS 네트워킹 & 인프라

**이 주차의 목표**: AWS 서비스 이전에 Linux/OS 수준의 원리를 먼저 이해하고, 이후 모든 실습의 기반이 되는 네트워크 구조를 직접 만든다.
"하나의 EC2에 여러 앱을 다른 포트로 띄우는 것이 어떻게 가능한가"를 OS 레벨부터 이해하는 것이 목표.

---

### Part A: Linux / OS 기초 원리

#### 개념 1. TCP 포트 바인딩 원리

프로세스가 네트워크 통신을 하려면 OS에 소켓(Socket)을 요청해야 한다. 소켓은 `IP:PORT` 조합으로 식별되며, 파일 디스크립터(FD)로 관리된다.

```
프로세스 (Apache)
    │
    │  socket() → OS가 소켓 생성
    │  bind(8088) → "이 소켓은 8088 포트 담당"
    │  bind(8089) → "이 소켓은 8089 포트 담당"
    │  listen()  → 연결 대기 시작
    ▼
커널 포트 매핑 테이블에 등록
```

외부 패킷이 들어오면 커널이 목적지 포트를 보고 해당 포트를 바인딩한 프로세스의 소켓으로 전달한다.

**핵심 케이스 두 가지**:
```
케이스 1. 하나의 프로세스가 포트 2개 바인딩 (Apache 멀티포트)
  Apache (PID 4444)
    → bind(8088)  소켓 FD#5   (Set A 트래픽)
    → bind(8089)  소켓 FD#6   (Set B 트래픽)
  → VirtualHost로 포트별 동작 분기

케이스 2. 프로세스 2개가 각각 다른 포트 바인딩 (앱이 다른 경우)
  was-pc  (PID 1111) → bind(8082)
  was-mo  (PID 2222) → bind(8083)
  → 완전히 독립된 두 프로세스, 같은 EC2 안에서 동작
```

포트를 구분하는 것은 커널이다. 하나의 프로세스가 소켓을 여러 개 열면 여러 포트를 동시에 Listen할 수 있다.
이미 바인딩된 포트에 다른 프로세스가 `bind()` 시도 → `Address already in use` 에러.

```bash
# 어떤 프로세스가 어떤 포트를 바인딩했는지 확인
ss -tlnp

# 출력 예시:
# LISTEN  0  128  0.0.0.0:8082  0.0.0.0:*  users:(("java",pid=1111,fd=7))  ← was-pc
# LISTEN  0  128  0.0.0.0:8083  0.0.0.0:*  users:(("java",pid=2222,fd=7))  ← was-mo
```

---

#### 개념 2. 프로세스 격리와 공유 자원

OS는 각 프로세스에게 가상 주소 공간(Virtual Address Space)을 별도로 준다. was-pc와 was-mo는 각자의 메모리 공간에서 독립적으로 동작한다.

```
물리 RAM (8GB)
┌──────────────────────────────────────┐
│  was-pc (PID 1111)  가상 0x0~0xFFF   │
│      → 물리 주소 0x1000~0x2FFF 매핑  │
│                                      │
│  was-mo (PID 2222)  가상 0x0~0xFFF   │
│      → 물리 주소 0x5000~0x7FFF 매핑  │
└──────────────────────────────────────┘
```

**독립 자원 vs 공유 자원**:

| 자원 | 독립? | 설명 |
|------|-------|------|
| 메모리 (Heap) | **독립** | 가상 주소 공간으로 분리 — 상대방 메모리 침범 불가 |
| 포트 | **독립** | 커널 매핑 테이블로 분리 |
| CPU | **공유** | 스케줄러가 시분할로 나눠줌 |
| 네트워크 대역폭 | **공유** | NIC 하나를 같이 씀 |
| Disk I/O | **공유** | 디스크 컨트롤러 하나 |

**Noisy Neighbor 문제**: was-mo에서 Full GC가 발생해 CPU 4코어를 순간 점유하면, was-pc의 요청 처리 스레드들이 CPU 할당을 못 받고 응답 지연이 생긴다. was-pc 자체는 살아있고 메모리도 멀쩡하지만.

**Docker 컨테이너**: 동일한 EC2 커널을 공유하되 네임스페이스(PID/NET/MNT)로 격리를 추가한 것. 근본 원리는 프로세스와 같다. CPU/네트워크 Noisy Neighbor는 여전히 존재하며, cgroup(`--cpus`, `--memory`)으로 상한선을 걸 수 있다.

---

#### 개념 3. systemd 서비스 관리 + zip 배포 연결

**zip 파일 안에 들어있는 것**:
```
price-was-pc-v1.zip
├── app-pc.jar          ← 실행 파일
├── application.yml     ← 앱 설정 (포트, DB 주소 등)
└── was-pc.service      ← systemd unit 파일
```

zip 하나 = 한 프로세스를 띄우는 데 필요한 모든 것.

**EC2 User Data 스크립트 (첫 부팅 시 한 번 실행)**:
```bash
#!/bin/bash
# was-pc, was-mo 두 앱을 하나의 EC2에 셋업하는 예시

mkdir -p /opt/apps/was-pc /opt/apps/was-mo

aws s3 cp s3://deploy-bucket/was-pc-v1.zip /tmp/
aws s3 cp s3://deploy-bucket/was-mo-v1.zip /tmp/

unzip /tmp/was-pc-v1.zip -d /opt/apps/was-pc/
unzip /tmp/was-mo-v1.zip -d /opt/apps/was-mo/

cp /opt/apps/was-pc/was-pc.service /etc/systemd/system/
cp /opt/apps/was-mo/was-mo.service /etc/systemd/system/
systemctl daemon-reload

systemctl enable was-pc was-mo
systemctl start was-pc   # → JVM PID 1111, 8082 바인딩
systemctl start was-mo   # → JVM PID 2222, 8083 바인딩
```

**systemd unit 파일 핵심**:
```ini
[Service]
ExecStart=/usr/bin/java -jar app-pc.jar --server.port=8082
Restart=on-failure   # 프로세스가 비정상 종료되면 자동 재시작
RestartSec=5
```

`--server.port=8082` 이 값이 커널에 `bind()`될 포트 번호를 결정한다.
`Restart=on-failure`: JVM이 OOM 등으로 죽어도 5초 후 자동 재시작. `systemctl stop`은 재시작하지 않음.

**재배포 흐름 (Set B에 새 버전 배포 시)**:
```
1. systemctl stop was-pc
   → JVM 종료 → 커널에서 8082 매핑 해제
2. 새 zip 압축 해제 (파일 교체)
3. systemctl start was-pc
   → 새 JVM 기동 → 커널에 8082 재등록
4. Health Check → ALB Target Group 트래픽 전환
※ was-mo(8083)는 이 과정 내내 전혀 건드리지 않음
```

**세 개념의 연결**:
```
[포트 바인딩]  커널이 포트-프로세스 매핑 관리
    +
[프로세스 격리] 각 프로세스는 독립 메모리. CPU/Disk는 공유
    +
[systemd]      zip 안의 unit 파일이 "어떻게 띄울지" 정의
               Restart=on-failure로 단순 고가용성 확보
               배포 = stop → 파일 교체 → start → health check
```

---

### Part B: AWS 네트워킹 & 인프라

#### 개념 1. VPC 내부 동작 원리

VPC(Virtual Private Cloud)는 AWS에서 만드는 나만의 가상 사설 네트워크다. NLB, Apache EC2, WAS EC2, Redis, RDS가 모두 이 안에 존재한다.

**CIDR과 Subnet 설계**:
```
VPC: 10.0.0.0/16  (사용 가능 IP: 10.0.0.0 ~ 10.0.255.255)
│
├── Public Subnet  10.0.1.0/24  (AZ-a)  ← NLB, NAT GW, Bastion
├── Public Subnet  10.0.2.0/24  (AZ-c)
├── Private Subnet 10.0.3.0/24  (AZ-a)  ← Apache EC2 (Web)
├── Private Subnet 10.0.4.0/24  (AZ-c)
├── Private Subnet 10.0.5.0/24  (AZ-a)  ← WAS EC2 (was-pc, was-mo)
├── Private Subnet 10.0.6.0/24  (AZ-c)
├── Private Subnet 10.0.7.0/24  (AZ-a)  ← Redis, RDS
└── Private Subnet 10.0.8.0/24  (AZ-c)
```

Subnet을 AZ별로 2개씩 만드는 이유: AZ 하나가 장애나도 서비스가 유지되기 위함.

**Public vs Private Subnet 차이**: Route Table에 Internet Gateway(IGW) 경로가 있냐 없냐.

**Private EC2가 ECR/S3에 접근하는 경로**:
```
NAT Gateway 방식 (인터넷 경유, 비용 발생)
  Private EC2 → NAT GW (Public Subnet) → 인터넷 → ECR

VPC Endpoint 방식 (AWS 내부망, 권장)
  Private EC2 → VPC Endpoint → ECR (인터넷 미경유, 더 빠르고 안전)
```
ECR, S3, SSM 등 AWS 서비스는 VPC Endpoint로 연결하는 것이 일반적.

---

#### 개념 2. Security Group vs NACL

두 계층의 방화벽이 공존한다:

```
인터넷
  │
  ▼
NACL (Subnet 경계에서 검사)   ← Stateless
  │
  ▼
Security Group (EC2 인스턴스 경계에서 검사)   ← Stateful
  │
  ▼
EC2
```

| | Security Group | NACL |
|---|---|---|
| 적용 단위 | EC2 인스턴스 | Subnet |
| 상태 추적 | **Stateful** (연결 기억) | **Stateless** (패킷 독립 판단) |
| 규칙 방향 | Inbound만 써도 응답 자동 허용 | Inbound/Outbound 둘 다 필요 |
| 기본 동작 | 모든 Inbound 차단 | 모든 트래픽 허용 |

**Stateful의 의미**: SG가 Inbound 8082를 허용하면, 그 응답 패킷은 Outbound 규칙 없이 자동 통과. 커널이 "이건 내가 아까 허용한 요청의 응답"임을 기억하기 때문.

**왜 두 개가 공존하는가**:
- NACL: Subnet 자체를 IP 대역 단위로 차단 (DDoS 대응, Subnet 간 격리)
- SG: 같은 Subnet 안에서도 인스턴스 단위 세밀한 제어

**우리 아키텍처 SG 설계**:
```
SG-web (Apache EC2)
  Inbound:  8088, 8089  출처: NLB IP 대역
  Outbound: 8080        대상: SG-was

SG-was (WAS EC2)
  Inbound:  8080        출처: SG-web
  Outbound: 6379, 3306  대상: SG-redis, SG-rds

SG-redis
  Inbound:  6379        출처: SG-was

SG-rds
  Inbound:  3306        출처: SG-was
```

출처를 IP가 아닌 SG 이름으로 지정 → EC2 재시작으로 IP가 바뀌어도 규칙 유지.

---

#### 개념 3. IAM Role

**핵심 문제**: User Data 스크립트에서 `aws s3 cp ...`를 실행할 때 EC2가 S3에 접근할 권한을 어떻게 갖는가?

**절대 하면 안 되는 방법**: Access Key를 EC2 안에 하드코딩. 탈취 시 키도 탈취됨.

**IAM Role**: EC2 자체에 권한을 부여하는 방식. EC2가 부팅되면 AWS가 자동으로 임시 자격증명을 발급하고, 메타데이터 서버에 저장한다.

```
EC2 안의 모든 프로세스 (User Data, JVM, 배포 스크립트)
    │
    │  AWS CLI / SDK 호출 시 자동으로
    ▼
메타데이터 서버: http://169.254.169.254/latest/meta-data/iam/security-credentials/
    │
    │  임시 자격증명 반환 (6시간마다 자동 교체)
    ▼
AWS API 호출 성공 (키를 코드에 저장하지 않아도 됨)
```

**우리 아키텍처에서 Role이 쓰이는 곳**:
```
EC2-WAS-Role
  ├── S3 GetObject       → zip 다운로드
  ├── ECR pull           → Docker 이미지 pull
  ├── SSM GetParameter   → DB 비밀번호, Redis 주소 읽기
  └── CloudWatch Logs    → 로그 전송

GitHub Actions Role (4주차)
  ├── ECR push           → 이미지 빌드 후 업로드
  ├── EC2 DescribeInstances → Tag로 대상 EC2 조회
  └── SSM SendCommand    → EC2에 배포 명령 원격 실행
```

---

#### 개념 4. AMI, Launch Template, User Data

세 가지가 합쳐져서 EC2가 뜨자마자 서비스 가능한 상태를 만든다.

**AMI**: EC2를 찍어내는 틀. Custom AMI를 쓰면 java/docker가 이미 설치된 상태에서 시작 → 부팅 시간 단축 (7분 → 1~2분).

**Launch Template**: EC2 생성 명세서. 인스턴스 타입, SG, IAM Role, 태그 등을 미리 정의.
```
Launch Template: price-was-template
├── AMI ID, Instance Type, Security Group, IAM Role
└── Tags:
      application: mo
      lane:        primary
      stageNo:     0
      set:         A
      role:        was
```

배포 스크립트가 나중에 `describe-instances --filters tag:set=B`로 EC2를 찾을 수 있는 이유는 이 태그가 Launch Template에 박혀있기 때문.

**User Data**: EC2 첫 부팅 시 딱 한 번 실행되는 스크립트. 디렉토리 생성 → zip 다운로드 → 압축 해제 → systemd 등록 → 서비스 기동의 흐름으로 앱을 셋업한다.

**전체 연결**:
```
배포 스크립트
  → run-instances (Launch Template 지정)
  → EC2 부팅 → User Data 실행
  → was-pc(8082), was-mo(8083) 자동 기동
  → Health Check 통과
  → ALB Target Group 등록
  → 트래픽 유입
```

---

#### 개념 5. NLB vs ALB

차이는 패킷을 어느 계층까지 열어보느냐.

```
OSI 계층
  7 Application  HTTP, HTTPS   ← ALB가 여기까지 봄
  4 Transport    TCP, Port     ← NLB는 여기까지만 봄
```

**NLB (L4)**:
- 패킷 내용 파싱 없음 → 극저지연
- 고정 IP 제공 → 방화벽에 IP 등록 가능 (ALB는 DNS 기반으로 IP가 바뀜)
- 포트 기반 라우팅: 8088 → Web SetA, 8089 → Web SetB
- Blue-Green 전환 = NLB Listener의 Target Group 교체

**ALB (L7)**:
- HTTP 헤더, URL 경로, 쿼리스트링까지 파싱
- 경로 기반: `/api/pc/**` → WAS-PC, `/api/mo/**` → WAS-MO
- 헤더 기반: `X-Set: A` → WAS SetA, `X-Set: B` → WAS SetB
- SSL 종료: HTTPS를 ALB에서 복호화 → 내부는 HTTP

**왜 NLB가 앞에, ALB가 뒤에 있는가**:
```
방화벽에 고정 IP를 등록해야 함 → NLB (고정 IP)
Apache 뒤에서 was-pc/was-mo를 URL 경로로 분기해야 함 → ALB (L7 정보 필요)
NLB는 HTTP 내용을 못 보므로 이 역할 불가
```

---

#### 개념 6. ECR

AWS의 프라이빗 Docker 이미지 저장소. IAM Role로 push/pull 인증.

**이미지 태그 전략**:
```
price-was:primary-0-A-abc1234   ← {lane}-{stageNo}-{set}-{git-sha}
```
롤백 = 이전 태그로 컨테이너 교체.

**인증 흐름**: GitHub Actions(push)와 EC2(pull) 모두 Access Key 없이 IAM Role의 임시 자격증명으로 인증.

---

### 핵심 질문 (주말까지 스스로 답할 수 있어야 함)

1. 하나의 EC2에서 Apache가 8088과 8089를 동시에 Listen할 수 있는 OS 레벨 원리는?
2. was-mo가 OOM으로 죽었을 때 was-pc는 왜 영향받지 않는가? 무엇이 영향받는가?
3. `systemctl restart was-pc`로 배포할 때 was-mo 트래픽이 끊기지 않는 이유는?
4. Private Subnet의 EC2가 ECR에서 이미지를 pull하는 경로는? (NAT Gateway vs VPC Endpoint)
5. Security Group은 왜 "Stateful"인가? (응답 트래픽에 별도 규칙이 없어도 되는 이유)

### 실습 (`week1/practice/` 디렉토리 참고)

- `01-port-binding/run.sh`: Python HTTP 서버 2포트 기동 → 하나 kill 후 나머지 생존 확인
- `02-systemd/`: was-pc.service, was-mo.service unit 파일 직접 작성 + `Restart=on-failure` 검증
- `03-aws-infra/`: VPC 설계, Security Group 규칙, Launch Template, IAM Policy 문서화

---

