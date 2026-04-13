#!/bin/bash
# 실습: 하나의 EC2에서 두 포트로 독립적인 프로세스 띄우기
#
# 목적:
#   - was-pc(:8082)와 was-mo(:8083)이 독립적으로 동작하는 것 확인
#   - 하나를 죽여도 나머지가 살아있음을 확인 (프로세스 격리 원리)

echo "=== [1] 두 포트로 Python HTTP 서버 기동 ==="

# was-pc 역할 (포트 8082)
python3 -m http.server 8082 &
WAS_PC_PID=$!
echo "was-pc 기동 완료 | PID: $WAS_PC_PID | PORT: 8082"

# was-mo 역할 (포트 8083)
python3 -m http.server 8083 &
WAS_MO_PID=$!
echo "was-mo 기동 완료 | PID: $WAS_MO_PID | PORT: 8083"

sleep 1

echo ""
echo "=== [2] 커널 포트 매핑 확인 (ss -tlnp) ==="
# 8082, 8083 포트가 각각 다른 PID로 바인딩된 것을 확인
ss -tlnp | grep -E '8082|8083'

echo ""
echo "=== [3] 각 프로세스 응답 확인 ==="
echo "[was-pc:8082 응답]"
curl -s http://localhost:8082 | head -5

echo ""
echo "[was-mo:8083 응답]"
curl -s http://localhost:8083 | head -5

echo ""
echo "=== [4] was-pc 프로세스 강제 종료 ==="
kill -9 $WAS_PC_PID
echo "was-pc(PID: $WAS_PC_PID) 종료"
sleep 1

echo ""
echo "=== [5] was-mo는 여전히 살아있는지 확인 ==="
# was-pc는 응답 없음, was-mo는 정상 응답 → 프로세스 격리 원리 확인
echo "[was-pc:8082 응답 시도 - Connection refused 예상]"
curl -s --max-time 2 http://localhost:8082 || echo ">>> was-pc 응답 없음 (정상)"

echo ""
echo "[was-mo:8083 응답 시도 - 정상 응답 예상]"
curl -s http://localhost:8083 | head -3 && echo ">>> was-mo 정상 동작 중"

echo ""
echo "=== [6] 정리: was-mo 종료 ==="
kill -9 $WAS_MO_PID
echo "was-mo(PID: $WAS_MO_PID) 종료"

echo ""
echo "=== 실습 완료 ==="
echo "확인한 것:"
echo "  1. 하나의 EC2에서 포트가 다른 두 프로세스가 독립적으로 동작"
echo "  2. was-pc를 강제 종료해도 was-mo는 영향받지 않음"
echo "  3. 프로세스 격리 = 메모리/포트 독립, CPU/네트워크는 공유"
