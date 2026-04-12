# 상품가격 적재 프로세스 POC

> 인프라팀 실무 아키텍처를 직접 구현하며 핵심 기술 원리를 체득하는 7주 학습 프로젝트.
> 단순 구현이 아닌 **"왜 이렇게 동작하는가"** 를 이해하는 것이 목표.

---

## 최종 구현 아키텍처

### 전체 요청 흐름

```
 ┌──────────────────────────────────────────────────────────────┐
 │                      Client  (MO / PC)                       │
 └────────────────────────────┬─────────────────────────────────┘
                              │
                    ┌─────────▼─────────┐
                    │      방화벽        │  IP/Port 기반 접근 제어
                    └─────────┬─────────┘
                              │
                    ┌─────────▼─────────┐
                    │    NLB  (L4)       │  고정 IP, 극저지연
                    │  :8088  │  :8089   │  ← Set A / Set B 포트 분리
                    └────┬────┴────┬─────┘
                         │         │
              ┌──────────▼─────────▼──────────┐
              │       Apache httpd  (Web)      │
              │                               │
              │  VirtualHost *:8088 (Set A)   │
              │  VirtualHost *:8089 (Set B)   │
              │        │             │        │
              │   /img/**       /api/**       │
              └────┬───┴─────────────┬────────┘
                   │                 │
                   ▼                 ▼
               S3 Bucket       ┌─────────────┐
            (정적 이미지)       │  ALB  (L7)  │  Path/Header 기반 라우팅
                               └──────┬──────┘
                                      │
                       ┌──────────────┴──────────────┐
                       │                             │
              ┌────────▼────────┐          ┌────────▼────────┐
              │  WAS  Set A     │          │  WAS  Set B     │
              │  Tomcat :8080   │          │  Tomcat :8080   │
              │  (Blue / 운영)  │          │ (Green / 대기)  │
              └────────┬────────┘          └────────┬────────┘
                       └──────────┬──────────────────┘
                                  │
                         ┌────────▼────────┐
                         │     Redis        │
                         │  price:setA:*   │
                         │  price:setB:*   │
                         └────────┬────────┘
                                  │
                         ┌────────▼────────┐
                         │  RDS  (MySQL)    │
                         │  가격 원천 DB    │
                         └─────────────────┘
```

---

### 가격 데이터 파이프라인

```
 ┌─────────────┐  binlog CDC  ┌──────────┐  produce  ┌────────────────────┐
 │ RDS (MySQL) │ ────────────► │ AWS DMS  │ ─────────► │      Kafka         │
 └─────────────┘              └──────────┘            │  topic: price-setA │
                                                       │  topic: price-setB │
 ┌─────────────┐  cron                                 └─────────┬──────────┘
 │    Batch    │ ── 예약가격 ─────────────────────────────────── ► │
 │  Scheduler  │    체크                                           │ consume
 └─────────────┘                                       ┌──────────▼──────────┐
                                                        │        Redis        │
                                                        │  price:setA:{id}   │
                                                        │  price:setB:{id}   │
                                                        └─────────────────────┘
```

---

### CI/CD 파이프라인 (GitHub Actions)

```
  Git Push / workflow_dispatch
  (lane / stageNo / set / app 선택)
            │
            ▼
  ┌──────────────────────────────────────────────────────┐
  │              GitHub Actions Runner                    │
  │                                                      │
  │  ┌──────────┐    ┌──────────┐    ┌────────────────┐ │
  │  │  build   │───►│   push   │───►│    deploy      │ │
  │  │ mvn pkg  │    │ ECR push │    │ EC2 Tag 조회   │ │
  │  │  docker  │    │          │    │ SSM 배포       │ │
  │  │  build   │    │          │    │ Health Check   │ │
  │  └──────────┘    └──────────┘    │ NLB TG 전환   │ │
  │                                  └────────────────┘ │
  └──────────────────────────────────────────────────────┘
            │  OIDC 인증 (장기 자격증명 없음)
            ▼
  ┌─────────────────────────────────────┐
  │  EC2  (tag: lane=primary, set=B)    │
  │                                     │
  │  ① 구 컨테이너 Stop                 │
  │  ② ECR 이미지 Pull                  │
  │  ③ 신규 컨테이너 Run                │
  │  ④ Health Check 통과                │
  │  ⑤ NLB 포트 전환 (8088 ↔ 8089)    │
  └─────────────────────────────────────┘
```

---

### 로그 수집 (ELK Stack)

```
  EC2 (Web / WAS)                                        Kibana
  ┌──────────────┐   ┌──────────────────────────┐   ┌──────────────────┐
  │  access.log  │   │        Logstash           │   │  Lane별 대시보드  │
  │  app.log     │──►│  Input  → Filter → Output │──►│  Set별 요청수    │
  └──────────────┘   │  Beats     Grok    ES     │   │  에러 로그 추적  │
   Filebeat 수집      └──────────────────────────┘   └──────────────────┘
   (inode tracking)            │
                          Elasticsearch
                          (Inverted Index)
```

---

## 배포 환경 구조

```
  Lane      Set   stageNo   Port    용도
  ──────────────────────────────────────────────────────
  primary   A       -       8088    운영 (Blue  / 현재 라이브)
  primary   B       -       8089    운영 (Green / 신규 배포)
  ──────────────────────────────────────────────────────
  stage     A     1/2/3     8088    개발 (프로젝트별 독립 환경)
  stage     B     1/2/3     8089    개발 (신규 배포 대기)
  ──────────────────────────────────────────────────────
  preview   A       -       8088    QA / 검수
  preview   B       -       8089    QA / 검수 신규 배포
  ──────────────────────────────────────────────────────
                                    총 10개 Set
```

---

## 6주 학습 로드맵

| 주차 | 주제 | 핵심 기술 |
|------|------|-----------|
| **Week 1** | Linux/OS 기초 + AWS 네트워킹 | TCP 포트 바인딩, systemd, VPC, NLB/ALB, IAM |
| **Week 2** | Docker + 로컬 Blue-Green 실습 | Dockerfile, Docker Compose, Immutable 배포, Apache 멀티포트 |
| **Week 3** | AWS Blue-Green 무중단 배포 | ASG, Target Group, Connection Draining, 멀티앱 EC2 패턴 |
| **Week 4** | GitHub Actions CI/CD 자동화 | Workflow, OIDC 인증, ECR, Tag 기반 배포 스크립트 |
| **Week 5** | Kafka + DMS CDC 파이프라인 | Partition/Offset, Consumer Group, binlog CDC |
| **Week 6** | Redis 캐시 + ELK 로그 수집 | Hash 구조, TTL 전략, Filebeat, Logstash Grok |
| **Week 7** | **통합 구현** | 전체 아키텍처 End-to-End 구현 + 장애 시나리오 |

---

## 기술 스택

| 영역 | 기술 |
|------|------|
| **인프라** | AWS VPC · EC2 · NLB · ALB · ASG · S3 · ECR · ElastiCache · RDS |
| **배포** | GitHub Actions · Docker · Apache httpd · Tomcat · systemd |
| **데이터** | Apache Kafka (KRaft) · AWS DMS · Redis · MySQL |
| **관찰** | Elasticsearch · Logstash · Kibana · Filebeat |

---

## 브랜치 전략

```
  main  ←  Week 7 최종 통합 결과물
   │
   ├── week1/linux-os-aws-networking
   ├── week2/docker-bluegreen-local
   ├── week3/alb-asg-bluegreen-aws
   ├── week4/github-actions-cicd
   ├── week5/kafka-dms-pipeline
   └── week6/redis-elk-stack
```

> 📋 주차별 상세 학습 계획 → [학습 계획 상세 문서](https://github.com/JEEEEEEHO/Price_PipeLine_POC/blob/main/.claude/plans/shiny-leaping-alpaca.md)
