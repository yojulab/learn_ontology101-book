#!/usr/bin/env bash
# ==============================================================================
# 서울시 실시간 인구 RDF(Turtle) 데이터 Fuseki 적재 스크립트
#
# cURL 명령어로 생성된 TTL 파일(gangnam-*.ttl 또는 gangnam.ttl)을
# Apache Jena Fuseki의 /fc 데이터셋 Named Graph로 전송(POST)합니다.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 도움말 출력
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat << EOF
사용법: $0 [TTL_FILE] [GRAPH_URI]

설명:
  지정된 Turtle(.ttl) 파일을 Apache Jena Fuseki Graph Store에 POST 적재합니다.

인자:
  TTL_FILE   업로드할 TTL 파일 경로 (기본값: gangnam-202610262126.ttl 또는 최신 gangnam-*.ttl)
  GRAPH_URI  적재할 Named Graph IRI (기본값: http://k.gangnam/onto)

환경변수:
  FUSEKI_URL  Fuseki 서버 주소 (기본값: http://localhost:3030)
  DATASET     Fuseki 데이터셋 이름 (기본값: fc)
  GRAPH_URI   Named Graph IRI (기본값: http://k.gangnam/onto)

예시:
  $0
  $0 gangnam-202610262126.ttl
  $0 gangnam.ttl http://k.fc/onto
EOF
  exit 0
fi

# 프로젝트 루트의 .env 환경변수 로드
ENV_FILE="$(cd "${SCRIPT_DIR}/../.." && pwd)/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
fi

# Fuseki 서버 및 Graph 설정
FUSEKI_URL="${FUSEKI_URL:-http://localhost:3030}"
DATASET="${DATASET:-fc}"
GRAPH_URI="${2:-${GRAPH_URI:-${GANGNAM_GRAPH_IRI:-http://k.gangnam/onto}}}"

# 업로드할 TTL 파일 지정 ($1 인자 우선, 없으면 gangnam.ttl)
if [ $# -ge 1 ]; then
  TTL_INPUT="$1"
else
  if [ -f "${SCRIPT_DIR}/gangnam.ttl" ]; then
    TTL_INPUT="${SCRIPT_DIR}/gangnam.ttl"
  else
    # 가장 최근에 생성된 gangnam-*.ttl 검색
    LATEST_TS_TTL="$(ls -t "${SCRIPT_DIR}"/gangnam-[0-9]*.ttl 2>/dev/null | head -n1 || true)"
    if [ -n "$LATEST_TS_TTL" ] && [ -f "$LATEST_TS_TTL" ]; then
      TTL_INPUT="$LATEST_TS_TTL"
    else
      TTL_INPUT="${SCRIPT_DIR}/gangnam.ttl"
    fi
  fi
fi

# 상대 경로 처리
if [ ! -f "$TTL_INPUT" ] && [ -f "${SCRIPT_DIR}/${TTL_INPUT}" ]; then
  TTL_INPUT="${SCRIPT_DIR}/${TTL_INPUT}"
fi

if [ ! -f "$TTL_INPUT" ]; then
  echo "[ERROR] TTL 파일을 찾을 수 없습니다: ${TTL_INPUT}" >&2
  exit 1
fi

TARGET_URL="${FUSEKI_URL}/${DATASET}/data?graph=${GRAPH_URI}"

echo "[INFO] Apache Jena Fuseki 데이터 적재 시작"
echo "  - 대상 파일:   ${TTL_INPUT}"
echo "  - Fuseki 주소: ${FUSEKI_URL}"
echo "  - 데이터셋:    /${DATASET}"
echo "  - Named Graph: ${GRAPH_URI}"
echo "  - 요청 URL:    ${TARGET_URL}"

# Fuseki 서버 연결 확인
if ! curl -s -m 2 "${FUSEKI_URL}/\$/ping" >/dev/null 2>&1; then
  echo "[ERROR] Fuseki 서버(${FUSEKI_URL})에 연결할 수 없습니다." >&2
  echo "        Fuseki 서버를 먼저 실행해주세요 (예: ./fuseki.sh start)" >&2
  exit 1
fi

# cURL POST 실행 (SPARQL 1.1 Graph Store HTTP Protocol)
RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
  -X POST \
  -H "Content-Type: text/turtle" \
  --data-binary @"${TTL_INPUT}" \
  "${TARGET_URL}")

HTTP_STATUS=$(echo "${RESPONSE}" | grep "HTTP_STATUS:" | cut -d':' -f2 | tr -d '\r\n')
BODY=$(echo "${RESPONSE}" | sed '/HTTP_STATUS:/d')

if [ "${HTTP_STATUS}" = "200" ] || [ "${HTTP_STATUS}" = "201" ] || [ "${HTTP_STATUS}" = "204" ]; then
  echo "[SUCCESS] 데이터 적재 완료 (HTTP ${HTTP_STATUS})"
  
  # Named Graph 내 현재 트리플 개수 확인
  COUNT_JSON=$(curl -s "${FUSEKI_URL}/${DATASET}/query" \
    --data-urlencode "query=SELECT (COUNT(?s) AS ?count) WHERE { GRAPH <${GRAPH_URI}> { ?s ?p ?o } }" \
    -H "Accept: application/sparql-results+json" 2>/dev/null || true)
  
  TOTAL_COUNT=$(echo "${COUNT_JSON}" | grep -o '"value": "[0-9]*"' | head -1 | cut -d'"' -f4 || true)
  if [ -n "${TOTAL_COUNT}" ]; then
    echo "  - Named Graph <${GRAPH_URI}> 현재 총 트리플 수: ${TOTAL_COUNT}개"
  fi
else
  echo "[ERROR] 데이터 적재 실패 (HTTP ${HTTP_STATUS}):" >&2
  echo "${BODY}" >&2
  exit 1
fi
