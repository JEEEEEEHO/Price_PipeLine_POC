#!/bin/bash
# EC2 User Data 스크립트 - WAS EC2 초기 셋업
#
# 실행 시점: EC2 첫 부팅 시 딱 한 번 (cloud-init이 root 권한으로 실행)
# 로그 확인: cat /var/log/cloud-init-output.log
#
# 전제 조건 (Custom AMI에 미리 설치되어 있어야 함):
#   - java 17
#   - awscli v2
#   - unzip
#
# IAM Role (EC2-WAS-Role) 이 있으므로 AWS CLI 호출 시 키 불필요
# → 메타데이터 서버(169.254.169.254)에서 임시 자격증명 자동 획득

set -e  # 에러 발생 시 즉시 중단

# ─── 1. 환경 변수 ──────────────────────────────────────────────────
LANE="primary"
STAGE_NO="0"
SET="A"
REGION="ap-northeast-2"
DEPLOY_BUCKET="price-deploy-bucket"
APP_VERSION="v1"

# ─── 2. SSM Parameter Store에서 민감 정보 읽기 ──────────────────────
# IAM Role 덕분에 키 없이 호출 가능
DB_URL=$(aws ssm get-parameter \
  --name "/price/${LANE}/db-url" \
  --with-decryption \
  --region "${REGION}" \
  --query "Parameter.Value" --output text)

REDIS_HOST=$(aws ssm get-parameter \
  --name "/price/${LANE}/redis-host" \
  --region "${REGION}" \
  --query "Parameter.Value" --output text)

# ─── 3. 앱 사용자 생성 ─────────────────────────────────────────────
useradd -m -s /bin/bash app || true
mkdir -p /var/log/was-pc /var/log/was-mo
chown app:app /var/log/was-pc /var/log/was-mo

# ─── 4. 앱 디렉토리 생성 및 zip 다운로드 ────────────────────────────
# was-pc (PC 가격 API, 포트 8082)
mkdir -p /opt/apps/was-pc
aws s3 cp "s3://${DEPLOY_BUCKET}/was-pc-${APP_VERSION}.zip" /tmp/
unzip -o /tmp/was-pc-${APP_VERSION}.zip -d /opt/apps/was-pc/

# was-mo (모바일 가격 API, 포트 8083)
mkdir -p /opt/apps/was-mo
aws s3 cp "s3://${DEPLOY_BUCKET}/was-mo-${APP_VERSION}.zip" /tmp/
unzip -o /tmp/was-mo-${APP_VERSION}.zip -d /opt/apps/was-mo/

# ─── 5. 설정 파일에 환경 정보 주입 ──────────────────────────────────
sed -i "s|DB_URL_PLACEHOLDER|${DB_URL}|g" /opt/apps/was-pc/application.yml
sed -i "s|REDIS_HOST_PLACEHOLDER|${REDIS_HOST}|g" /opt/apps/was-pc/application.yml

sed -i "s|DB_URL_PLACEHOLDER|${DB_URL}|g" /opt/apps/was-mo/application.yml
sed -i "s|REDIS_HOST_PLACEHOLDER|${REDIS_HOST}|g" /opt/apps/was-mo/application.yml

# ─── 6. 소유권 변경 ────────────────────────────────────────────────
chown -R app:app /opt/apps/was-pc /opt/apps/was-mo

# ─── 7. systemd unit 파일 등록 및 서비스 기동 ───────────────────────
cp /opt/apps/was-pc/was-pc.service /etc/systemd/system/
cp /opt/apps/was-mo/was-mo.service /etc/systemd/system/
systemctl daemon-reload

systemctl enable was-pc was-mo

systemctl start was-pc
# 커널 포트 매핑: 8082 → JVM PID (was-pc)

systemctl start was-mo
# 커널 포트 매핑: 8083 → JVM PID (was-mo)

# ─── 8. 기동 확인 ──────────────────────────────────────────────────
sleep 10

echo "=== was-pc Health Check ==="
curl -f http://localhost:8082/health && echo "was-pc OK" || echo "was-pc FAILED"

echo "=== was-mo Health Check ==="
curl -f http://localhost:8083/health && echo "was-mo OK" || echo "was-mo FAILED"

echo "=== 포트 바인딩 확인 ==="
ss -tlnp | grep -E '8082|8083'

echo "=== User Data 완료 ==="
