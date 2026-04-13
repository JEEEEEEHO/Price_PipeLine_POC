# Week 1 핵심 질문 답변

학습 계획서의 핵심 질문 5가지에 대한 답변.
각 질문을 스스로 답할 수 있는지 확인하는 용도로 활용.

---

## Q1. 하나의 EC2에서 Apache가 8088과 8089를 동시에 Listen할 수 있는 OS 레벨 원리는?

**답변**:

프로세스는 OS에 `socket()` 시스템 콜로 소켓을 요청하고, `bind(포트번호)`로 포트를 점유한다.
하나의 프로세스가 소켓을 여러 개 생성하면 여러 포트를 동시에 바인딩할 수 있다.

```
Apache (PID 4444)
  bind(8088) → 소켓 FD#5 생성, 커널 포트 테이블에 "8088 → PID 4444" 등록
  bind(8089) → 소켓 FD#6 생성, 커널 포트 테이블에 "8089 → PID 4444" 등록
```

외부 패킷이 들어오면 커널이 목적지 포트를 보고 해당 소켓으로 전달한다.
Apache는 `httpd.conf`의 `Listen 8088`, `Listen 8089` 지시어로 이 두 소켓을 열고,
`<VirtualHost *:8088>`, `<VirtualHost *:8089>` 블록으로 포트별 동작을 분기한다.

---

## Q2. was-mo가 OOM으로 죽었을 때 was-pc는 왜 영향받지 않는가? 무엇이 영향받는가?

**답변**:

**영향받지 않는 것 (독립 자원)**:
- **메모리**: 각 프로세스는 OS로부터 독립된 가상 주소 공간을 받는다. was-mo의 메모리 공간과 was-pc의 메모리 공간은 커널이 물리 메모리에 겹치지 않게 매핑한다. was-mo가 OOM으로 죽어도 was-pc의 메모리는 전혀 침범당하지 않는다.
- **포트**: was-pc가 바인딩한 8082 소켓은 was-mo와 무관하다. was-mo(8083)가 죽어도 8082는 계속 살아있다.

**영향받는 것 (공유 자원)**:
- **CPU**: was-mo가 OOM 직전에 GC 스레드를 많이 돌렸다면 그 순간 was-pc의 응답이 느려질 수 있다 (Noisy Neighbor).
- **Disk I/O**: was-mo가 힙 덤프 파일을 쓰면 was-pc의 로그 I/O가 지연될 수 있다.

---

## Q3. `systemctl restart was-pc`로 배포할 때 was-mo 트래픽이 끊기지 않는 이유는?

**답변**:

`systemctl restart was-pc`는 was-pc 프로세스(PID 1111)만 종료하고 재시작한다.
was-mo 프로세스(PID 2222)는 전혀 건드리지 않는다.

```
restart 시 일어나는 일:
  was-pc PID 1111 종료 → 커널에서 "8082 → PID 1111" 매핑 해제
  새 JVM 기동 (PID 3333) → 커널에 "8082 → PID 3333" 재등록

was-mo(8083, PID 2222)의 커널 매핑은 이 과정에서 전혀 변화 없음
→ was-mo로 들어오는 트래픽은 중단 없이 계속 처리됨
```

Linux 포트 바인딩의 독립성 덕분에 가능한 구조다.

---

## Q4. Private Subnet의 EC2가 ECR에서 이미지를 pull하는 경로는? (NAT Gateway vs VPC Endpoint)

**답변**:

**NAT Gateway 방식**:
```
Private EC2 → Route Table(0.0.0.0/0 → NAT GW) → NAT GW(Public Subnet) → 인터넷 → ECR
```
- 트래픽이 인터넷을 경유
- NAT GW 데이터 처리 요금 + 인터넷 전송 요금 발생
- EC2의 Private IP는 NAT GW의 Public IP로 변환되어 나감 (EC2 IP 외부 미노출)

**VPC Endpoint 방식 (권장)**:
```
Private EC2 → VPC Endpoint → ECR (AWS 내부 백본망)
```
- 인터넷 미경유
- 비용 절감, 속도 향상, 보안 강화
- ECR용 Endpoint 두 개 필요: `ecr.api` (API 호출), `ecr.dkr` (이미지 레이어 pull)
- S3 Endpoint도 필요: ECR 이미지 레이어가 S3에 저장되어 있기 때문

실제 운영 환경에서는 ECR, S3, SSM, CloudWatch 모두 VPC Endpoint로 연결하는 것이 일반적.

---

## Q5. Security Group은 왜 "Stateful"인가? (응답 트래픽에 별도 규칙이 없어도 되는 이유)

**답변**:

Stateful = 연결 상태(Connection State)를 추적한다는 의미다.

클라이언트가 WAS EC2의 8082 포트로 요청을 보낼 때:
1. SG Inbound 규칙에서 8082 허용 확인 → 패킷 통과
2. **커널의 Connection Tracking 테이블에 이 연결 정보를 기록**
   (`10.0.1.100:51234 → 10.0.5.50:8082`, 상태: ESTABLISHED)

WAS EC2가 응답을 돌려줄 때:
1. SG가 Outbound 규칙을 확인하기 전에 Connection Tracking 테이블 조회
2. "이 패킷은 이미 허용된 연결의 응답"임을 확인
3. Outbound 규칙과 무관하게 자동 통과

NACL은 Connection Tracking 없이 각 패킷을 독립적으로 판단하기 때문에 Stateless다.
응답 트래픽이 사용하는 Ephemeral Port(1024~65535)를 NACL Outbound에 명시적으로 열어야 하는 이유가 여기에 있다.
