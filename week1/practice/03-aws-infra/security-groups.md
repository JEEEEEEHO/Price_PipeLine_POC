# Security Group 설계

## 설계 원칙

- **최소 권한**: 필요한 포트/출처만 허용, 나머지 차단
- **SG 참조**: IP 대신 SG 이름을 출처로 지정 → EC2 재시작으로 IP가 바뀌어도 규칙 유지
- **Stateful**: Inbound 허용 시 응답 트래픽은 Outbound 규칙 없이 자동 허용

---

## SG 목록 및 규칙

### sg-nlb (NLB용)
> NLB는 실제로 SG를 지원하지 않으므로 NACL로 제어.
> 아래는 참고용 설계 의도.

| 방향 | 포트 | 출처/대상 | 설명 |
|---|---|---|---|
| Inbound | 8088 | 0.0.0.0/0 | 외부 클라이언트 (Set A 트래픽) |
| Inbound | 8089 | 0.0.0.0/0 | 외부 클라이언트 (Set B 트래픽) |

---

### sg-web (Apache EC2)

| 방향 | 포트 | 출처/대상 | 설명 |
|---|---|---|---|
| Inbound | 8088 | NLB IP 대역 | NLB → Apache (Set A 포트) |
| Inbound | 8089 | NLB IP 대역 | NLB → Apache (Set B 포트) |
| Inbound | 22 | sg-bastion | Bastion을 통한 SSH |
| Outbound | 8080 | sg-was | Apache → ALB → WAS |
| Outbound | 443 | 0.0.0.0/0 | S3 리다이렉트 응답 |

---

### sg-alb-internal (내부 ALB)

| 방향 | 포트 | 출처/대상 | 설명 |
|---|---|---|---|
| Inbound | 80 | sg-web | Apache에서 들어오는 /api 트래픽 |
| Outbound | 8082 | sg-was | ALB → was-pc |
| Outbound | 8083 | sg-was | ALB → was-mo |

---

### sg-was (WAS EC2)

| 방향 | 포트 | 출처/대상 | 설명 |
|---|---|---|---|
| Inbound | 8082 | sg-alb-internal | ALB → was-pc |
| Inbound | 8083 | sg-alb-internal | ALB → was-mo |
| Inbound | 22 | sg-bastion | Bastion을 통한 SSH |
| Outbound | 6379 | sg-redis | Redis 접속 |
| Outbound | 3306 | sg-rds | RDS 접속 |
| Outbound | 443 | VPC Endpoint | ECR pull, SSM, CloudWatch |

---

### sg-redis

| 방향 | 포트 | 출처/대상 | 설명 |
|---|---|---|---|
| Inbound | 6379 | sg-was | WAS에서만 접근 허용 |

---

### sg-rds

| 방향 | 포트 | 출처/대상 | 설명 |
|---|---|---|---|
| Inbound | 3306 | sg-was | WAS에서만 접근 허용 |

---

### sg-bastion (Bastion Host)

| 방향 | 포트 | 출처/대상 | 설명 |
|---|---|---|---|
| Inbound | 22 | 운영자 IP/32 | 특정 IP에서만 SSH 허용 |
| Outbound | 22 | sg-web, sg-was | Private EC2로 SSH 점프 |

---

## NACL vs Security Group 역할 분리

```
NACL (Subnet 경계)
  → 특정 IP 대역 전체 차단 (DDoS 대응, 외부 공격 IP 블록)
  → Subnet 간 격리 (Data Subnet은 Web Subnet에서 직접 접근 불가)
  → Stateless이므로 Inbound/Outbound 모두 명시 필요
  → Ephemeral Port (1024~65535) Outbound 허용 필수

Security Group (인스턴스 경계)
  → 같은 Subnet 안에서도 인스턴스별 세밀한 제어
  → SG 참조로 동적 IP 변화에 강건
  → Stateful → 응답 트래픽 자동 허용
```
