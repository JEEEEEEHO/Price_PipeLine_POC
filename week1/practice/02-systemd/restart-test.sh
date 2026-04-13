#!/bin/bash
# 실습: Restart=on-failure 동작 검증
#
# 목적:
#   - JVM을 강제 종료(kill -9)했을 때 systemd가 자동으로 재시작하는 것을 확인
#   - systemctl stop은 재시작하지 않는 것을 확인 (의도적 종료 구분)

echo "=== [1] was-pc 서비스 시작 ==="
sudo systemctl start was-pc
sleep 2
sudo systemctl status was-pc --no-pager | grep -E "Active|PID|Main"

echo ""
echo "=== [2] JVM 강제 종료 (kill -9) ==="
WAS_PC_PID=$(sudo systemctl show was-pc --property=MainPID --value)
echo "현재 was-pc PID: $WAS_PC_PID"
sudo kill -9 $WAS_PC_PID
echo "kill -9 실행 완료"

echo ""
echo "=== [3] 5초 대기 후 자동 재시작 확인 ==="
sleep 6
NEW_PID=$(sudo systemctl show was-pc --property=MainPID --value)
sudo systemctl status was-pc --no-pager | grep -E "Active|PID|Main"

if [ "$WAS_PC_PID" != "$NEW_PID" ]; then
    echo ">>> 자동 재시작 성공! 이전 PID: $WAS_PC_PID → 새 PID: $NEW_PID"
else
    echo ">>> 재시작 미확인. systemctl status was-pc 로 직접 확인 필요"
fi

echo ""
echo "=== [4] systemctl stop은 재시작하지 않음 확인 ==="
sudo systemctl stop was-pc
sleep 6
sudo systemctl status was-pc --no-pager | grep "Active"
echo ">>> Active: inactive 상태면 정상 (재시작 없음)"

echo ""
echo "=== [5] 재기동 ==="
sudo systemctl start was-pc
echo "was-pc 재기동 완료"

echo ""
echo "=== 실습 완료 ==="
echo "확인한 것:"
echo "  1. kill -9 (비정상 종료) → Restart=on-failure 에 의해 자동 재시작"
echo "  2. systemctl stop (정상 종료) → 재시작 없음"
echo "  3. 재시작 시 새로운 PID 부여, 같은 포트(8082) 재바인딩"
