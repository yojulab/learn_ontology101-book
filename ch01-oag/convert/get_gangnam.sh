#!/usr/bin/env bash
# ==============================================================================
# 서울시 실시간 인구 데이터(JSON) 저장 스크립트
#
# cURL 명령어로 강남역의 실시간 인구 데이터를 조회하여
# gangnam-[년월일시분].json 및 gangnam.json 파일로 저장합니다.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 프로젝트 루트의 .env 환경변수 로드
ENV_FILE="$(cd "${SCRIPT_DIR}/../.." && pwd)/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
fi

API_KEY="${S_API_KEY:-${SEOUL_API_KEY:-76706545646f74743534576e594c47}}"

# 현재 시각 [년월일시분] 형식 (예: 202610262128)
NOW="$(date +%Y%m%d%H%M)"
TS_OUTPUT="${SCRIPT_DIR}/gangnam-${NOW}.json"
LATEST_OUTPUT="${SCRIPT_DIR}/gangnam.json"

URL="http://openapi.seoul.go.kr:8088/${API_KEY}/json/citydata_ppltn/1/5/강남역"

echo "[INFO] 강남역 실시간 인구 데이터 수집 중..."
echo "  - URL: ${URL}"

# cURL 명령어 실행
curl -s "${URL}" > "${TS_OUTPUT}"

# 유효한 응답인지 확인
if grep -q "SeoulRtd.citydata_ppltn" "${TS_OUTPUT}"; then
  # gangnam.json 파일로도 복사
  cp "${TS_OUTPUT}" "${LATEST_OUTPUT}"
  echo "[SUCCESS] 저장이 완료되었습니다:"
  echo "  - 타임스탬프 파일: ${TS_OUTPUT}"
  echo "  - 기본 파일:      ${LATEST_OUTPUT}"
else
  echo "[ERROR] 데이터 수집 실패:"
  cat "${TS_OUTPUT}"
  exit 1
fi
