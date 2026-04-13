# VPC 설계

## CIDR 구조

```
VPC: 10.0.0.0/16
│
├── [Public Subnet] 10.0.1.0/24  AZ-a  → NLB, NAT Gateway, Bastion Host
├── [Public Subnet] 10.0.2.0/24  AZ-c  → NLB, NAT Gateway (이중화)
│
├── [Private Subnet - Web] 10.0.3.0/24  AZ-a  → Apache EC2 (was-pc/was-mo Set A)
├── [Private Subnet - Web] 10.0.4.0/24  AZ-c  → Apache EC2 (was-pc/was-mo Set B)
│
├── [Private Subnet - WAS] 10.0.5.0/24  AZ-a  → WAS EC2 (was-pc:8082, was-mo:8083)
├── [Private Subnet - WAS] 10.0.6.0/24  AZ-c  → WAS EC2 (이중화)
│
├── [Private Subnet - Data] 10.0.7.0/24  AZ-a  → Redis, RDS (Primary)
└── [Private Subnet - Data] 10.0.8.0/24  AZ-c  → Redis Replica, RDS (Standby)
```

Subnet을 AZ별로 2개씩 만드는 이유:
- AZ 하나가 장애나도 나머지 AZ의 Subnet에서 서비스 유지
- NLB/ALB는 Multi-AZ 설정 시 자동으로 트래픽을 살아있는 AZ로 라우팅

---

## Route Table 설계

### Public Subnet Route Table
| Destination | Target | 설명 |
|---|---|---|
| 10.0.0.0/16 | local | VPC 내부 통신 |
| 0.0.0.0/0 | Internet Gateway | 인터넷 트래픽 허용 |

### Private Subnet Route Table (Web/WAS)
| Destination | Target | 설명 |
|---|---|---|
| 10.0.0.0/16 | local | VPC 내부 통신 |
| 0.0.0.0/0 | NAT Gateway | 아웃바운드 인터넷 (ECR, S3 등) |

### Private Subnet Route Table (Data)
| Destination | Target | 설명 |
|---|---|---|
| 10.0.0.0/16 | local | VPC 내부 통신만 허용 |
| (없음) | - | 인터넷 접근 완전 차단 |

---

## VPC Endpoint 설계

NAT Gateway를 거치지 않고 AWS 서비스에 직접 접근 (인터넷 미경유, 비용 절감, 보안 강화)

| Endpoint | 타입 | 용도 |
|---|---|---|
| com.amazonaws.ap-northeast-2.ecr.api | Interface | ECR API 호출 |
| com.amazonaws.ap-northeast-2.ecr.dkr | Interface | Docker 이미지 pull |
| com.amazonaws.ap-northeast-2.s3 | Gateway | zip 파일 다운로드 |
| com.amazonaws.ap-northeast-2.ssm | Interface | SSM Parameter Store, Session Manager |
| com.amazonaws.ap-northeast-2.logs | Interface | CloudWatch Logs 전송 |

Private EC2가 ECR에서 이미지 pull하는 두 경로 비교:
```
NAT Gateway 경유:
  WAS EC2 → NAT GW (Public Subnet) → 인터넷 → ECR 엔드포인트
  → 비용: NAT GW 데이터 처리 요금 + 인터넷 전송 요금

VPC Endpoint 경유 (권장):
  WAS EC2 → VPC Endpoint → ECR (AWS 내부 백본망)
  → 비용 절감, 인터넷 미경유, 보안 강화
```

---

## 트래픽 흐름 전체 그림

```
인터넷
  │
  ▼
방화벽 (IP/포트 필터링)
  │
  ▼
NLB (Public Subnet, 고정 IP)
  :8088 → Apache EC2 :8088 (Web SetA)
  :8089 → Apache EC2 :8089 (Web SetB)
  │
  ▼
Apache EC2 (Private Subnet - Web)
  /img/** → S3 (리다이렉트)
  /api/** → ALB
  │
  ▼
ALB (Internal, Private)
  /api/pc/** → WAS EC2 :8082 (was-pc)
  /api/mo/** → WAS EC2 :8083 (was-mo)
  │
  ▼
WAS EC2 (Private Subnet - WAS)
  was-pc PID 1111 :8082
  was-mo PID 2222 :8083
  │
  ├── Redis (Private Subnet - Data) :6379
  └── RDS   (Private Subnet - Data) :3306
```
