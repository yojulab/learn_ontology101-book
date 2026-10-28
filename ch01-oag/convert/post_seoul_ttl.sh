#!/usr/bin/env bash
# ==============================================================================
# 서울시 실시간 인구 RDF(Turtle) 데이터 Fuseki 적재 스크립트
#
# cURL 명령어로 생성된 TTL 파일(seoul_ppltn.ttl 또는 gangnam.ttl)을
# Apache Jena Fuseki의 데이터셋 Named Graph로 전송(POST/PUT)하고 검증합니다.
# ==============================================================================

# 스크립트가 source 로 실행되었을 때 터미널 창이 닫히는(exit) 현상 방지
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  set -euo pipefail
  safe_exit() { exit "${1:-1}"; }
else
  # source / . 로 실행된 경우 exit 대신 return 호출하여 현재 셸(터미널) 유지
  safe_exit() { return "${1:-1}"; }
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 도움말 출력
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat << EOF
사용법: $0 [--replace|-r] [TTL_FILE] [GRAPH_URI]

설명:
  지정된 Turtle(.ttl) 파일을 Apache Jena Fuseki Graph Store에 적재합니다.
  적재 완료 후 Named Graph 내의 모든 장소(:Place)와 예측 레코드 수를 자동 검증합니다.

옵션 및 인자:
  --replace, -r  기존 Named Graph를 완전히 대체(PUT 방식)하여 새로 적재
  TTL_FILE       업로드할 TTL 파일 경로 (기본값: seoul_ppltn.ttl 또는 gangnam.ttl)
  GRAPH_URI      적재할 Named Graph IRI (기본값: http://k.gangnam/onto 또는 .env 설정값)

환경변수:
  FUSEKI_URL  Fuseki 서버 주소 (기본값: http://localhost:3030)
  DATASET     Fuseki 데이터셋 이름 (기본값: fc)
  GRAPH_URI   Named Graph IRI (기본값: http://k.gangnam/onto)

예시:
  $0
  $0 --replace
  $0 seoul_ppltn.ttl http://k.fc/onto
  $0 -r seoul_ppltn.ttl http://k.fc/onto
EOF
  safe_exit 0
fi

# HTTP 메서드 설정 (스냅샷 갱신을 위해 PUT 기본 적용, --append 시 POST)
HTTP_METHOD="PUT"
if [ "${1:-}" = "--append" ] || [ "${1:-}" = "-a" ]; then
  HTTP_METHOD="POST"
  shift
elif [ "${1:-}" = "--replace" ] || [ "${1:-}" = "-r" ]; then
  HTTP_METHOD="PUT"
  shift
fi

# 프로젝트 루트의 .env 환경변수 로드
ENV_FILE="$(cd "${SCRIPT_DIR}/../.." && pwd)/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
fi

# Fuseki 서버 및 Graph 설정 (기본 그래프: http://k.fc/onto)
FUSEKI_URL="${FUSEKI_URL:-http://localhost:3030}"
DATASET="${DATASET:-fc}"
GRAPH_URI="${2:-${GRAPH_URI:-${GRAPH_IRI:-http://k.fc/onto}}}"

# 업로드할 TTL 파일 지정 ($1 인자 우선)
if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
  TTL_INPUT="$1"
else
  if [ -f "${SCRIPT_DIR}/seoul_ppltn.ttl" ]; then
    TTL_INPUT="${SCRIPT_DIR}/seoul_ppltn.ttl"
  elif [ -f "${SCRIPT_DIR}/gangnam.ttl" ]; then
    TTL_INPUT="${SCRIPT_DIR}/gangnam.ttl"
  else
    LATEST_TS_TTL="$(ls -t "${SCRIPT_DIR}"/*.ttl 2>/dev/null | head -n1 || true)"
    if [ -n "$LATEST_TS_TTL" ] && [ -f "$LATEST_TS_TTL" ]; then
      TTL_INPUT="$LATEST_TS_TTL"
    else
      TTL_INPUT="${SCRIPT_DIR}/seoul_ppltn.ttl"
    fi
  fi
fi

# 상대 경로 처리
if [ ! -f "$TTL_INPUT" ] && [ -f "${SCRIPT_DIR}/${TTL_INPUT}" ]; then
  TTL_INPUT="${SCRIPT_DIR}/${TTL_INPUT}"
fi

if [ ! -f "$TTL_INPUT" ]; then
  echo "[ERROR] TTL 파일을 찾을 수 없습니다: ${TTL_INPUT}" >&2
  safe_exit 1
fi

TARGET_URL="${FUSEKI_URL}/${DATASET}/data?graph=${GRAPH_URI}"

echo "================================================================================"
echo "[INFO] Apache Jena Fuseki 온톨로지 적재 시작"
echo "  - 적재 파일:   ${TTL_INPUT}"
echo "  - HTTP 전송:   ${HTTP_METHOD} (${HTTP_METHOD/POST/추가 병합}/${HTTP_METHOD/PUT/그래프 완전 대체})"
echo "  - Fuseki 주소: ${FUSEKI_URL}"
echo "  - 데이터셋:    /${DATASET}"
echo "  - Named Graph: <${GRAPH_URI}>"
echo "================================================================================"

# Fuseki 서버 연결 확인
if ! curl -s -m 2 "${FUSEKI_URL}/\$/ping" >/dev/null 2>&1; then
  echo "[ERROR] Fuseki 서버(${FUSEKI_URL})에 연결할 수 없습니다." >&2
  echo "        Fuseki 서버를 먼저 실행해주세요 (예: ./fuseki.sh start)" >&2
  safe_exit 1
fi

# cURL 실행 (SPARQL 1.1 Graph Store HTTP Protocol)
RESPONSE=$(curl -s -w "\nHTTP_STATUS:%{http_code}" \
  -X "${HTTP_METHOD}" \
  -H "Content-Type: text/turtle" \
  --data-binary @"${TTL_INPUT}" \
  "${TARGET_URL}")

HTTP_STATUS=$(echo "${RESPONSE}" | grep "HTTP_STATUS:" | cut -d':' -f2 | tr -d '\r\n')
BODY=$(echo "${RESPONSE}" | sed '/HTTP_STATUS:/d')

if [ "${HTTP_STATUS}" = "200" ] || [ "${HTTP_STATUS}" = "201" ] || [ "${HTTP_STATUS}" = "204" ]; then
  echo "[SUCCESS] HTTP ${HTTP_METHOD} 데이터 적재 성공 (HTTP ${HTTP_STATUS})"
  echo ""
  echo "--------------------------------------------------------------------------------"
  echo "[검증] Named Graph <${GRAPH_URI}> 적재 현황 조회 중..."
  echo "--------------------------------------------------------------------------------"

  # 1) 전체 트리플 수 조회
  COUNT_QUERY="SELECT (COUNT(?s) AS ?count) WHERE { GRAPH <${GRAPH_URI}> { ?s ?p ?o } }"
  COUNT_JSON=$(curl -s "${FUSEKI_URL}/${DATASET}/query" \
    --data-urlencode "query=${COUNT_QUERY}" \
    -H "Accept: application/sparql-results+json" 2>/dev/null || true)
  TOTAL_COUNT=$(echo "${COUNT_JSON}" | grep -o '"value": "[0-9]*"' | head -1 | cut -d'"' -f4 || true)

  # 2) 적재된 장소(:Place) 목록 및 예측 데이터 수 조회
  PLACES_QUERY="PREFIX : <http://k.fc/onto#>
PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
SELECT ?place ?label (COUNT(?f) AS ?fcCount)
WHERE {
  GRAPH <${GRAPH_URI}> {
    ?place a :Place .
    OPTIONAL { ?place rdfs:label ?label }
    OPTIONAL { ?f a :Forecast ; :forPlace ?place }
  }
}
GROUP BY ?place ?label
ORDER BY ?label"

  PLACES_JSON=$(curl -s "${FUSEKI_URL}/${DATASET}/query" \
    --data-urlencode "query=${PLACES_QUERY}" \
    -H "Accept: application/sparql-results+json" 2>/dev/null || true)

  # Python으로 결과 파싱 및 표 형식 출력
  python3 -c "
import json, sys

total_triples = '${TOTAL_COUNT:-0}'
print(f'  - 총 트리플 수 : {int(total_triples):,}개')

try:
    data = json.loads('''${PLACES_JSON}''')
    bindings = data.get('results', {}).get('bindings', [])
    print(f'  - 적재된 장소 수: {len(bindings)}개 지역')
    for idx, b in enumerate(bindings, 1):
        place_uri = b.get('place', {}).get('value', '').split('#')[-1]
        label = b.get('label', {}).get('value', '이름없음')
        fc_n = b.get('fcCount', {}).get('value', '0')
        print(f'    {idx}. [{place_uri}] {label} (예측 레코드: {fc_n}건)')
except Exception as e:
    print(f'  - 장소 상세 파싱 오류: {e}')
"
  echo "================================================================================"
  safe_exit 0
else
  echo "[ERROR] 데이터 적재 실패 (HTTP ${HTTP_STATUS}):" >&2
  echo "${BODY}" >&2
  safe_exit 1
fi
