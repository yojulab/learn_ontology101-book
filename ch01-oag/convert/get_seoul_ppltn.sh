#!/usr/bin/env bash
# ==============================================================================
# 서울시 실시간 인구 데이터(JSON) 수집 스크립트
#
# cURL 명령어로 서울시 열린데이터광장(citydata_ppltn)의 실시간 인구 데이터를 조회하여
# 단일 또는 복합 지역의 데이터를 수집하고 통합 JSON 파일로 저장합니다.
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
POI_LIST_FILE="${SCRIPT_DIR}/seoul_poi_list.json"

# 도움말 출력
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  cat << EOF
사용법: $0 [옵션] [장소명1] [장소명2] ...

설명:
  서울시 열린데이터광장 실시간 인구 데이터(citydata_ppltn)를 조회하여 JSON으로 저장합니다.
  단일 지역뿐만 아니라 여러 복합 지역(여러 역 또는 핫스팟)을 한 번에 수집할 수 있습니다.
  수집된 모든 지역 데이터는 seoul_ppltn.json 에 통합되어 저장됩니다.

옵션:
  -l, --list            지원되는 서울시 실시간 인구 119개 핫스팟(지하철역 46곳 포함) 목록 출력
  -s, --search <단어>   키워드로 지원 핫스팟 검색 (예: $0 -s 대림, $0 -s 강남)
  -h, --help            도움말 출력

인자:
  장소명      조회할 핫스팟 장소명 또는 POI 코드 (여러 개 지정 가능)
              (생략 시 기본 강남권 4대 핫스팟 자동 수집: 강남역, 역삼역, 선릉역, 신논현역·논현역)
              예: $0 강남역 역삼역 선릉역 대림역
              예: $0 "강남역,역삼역"
              예: $0 잠실역 홍대입구역(2호선)

환경변수:
  S_API_KEY / SEOUL_API_KEY   서울시 OpenAPI 인증키
EOF
  safe_exit 0
fi

# 지원 핫스팟 목록 전체 출력 (--list, -l)
if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ]; then
  python3 -c "
import json
with open('${POI_LIST_FILE}', 'r', encoding='utf-8') as f:
    pois = json.load(f)

subways, spots = [], []
for c, n in sorted(pois.items()):
    (subways if '역' in n else spots).append((c, n))

print('================================================================================')
print(f'서울시 실시간 도시데이터 지원 핫스팟 목록 (총 {len(pois)}곳)')
print('================================================================================')
print(f'[지하철역 총 {len(subways)}곳]')
for i in range(0, len(subways), 3):
    chunk = subways[i:i+3]
    print('  ' + '  |  '.join(f'{c}: {n:<14}' for c, n in chunk))

print(f'\n[관광특구 및 주요 명소 총 {len(spots)}곳]')
for i in range(0, len(spots), 3):
    chunk = spots[i:i+3]
    print('  ' + '  |  '.join(f'{c}: {n:<14}' for c, n in chunk))
print('================================================================================')
"
  safe_exit 0
fi

# 지원 핫스팟 키워드 검색 (--search, -s)
if [ "${1:-}" = "--search" ] || [ "${1:-}" = "-s" ]; then
  KEYWORD="${2:-}"
  if [ -z "${KEYWORD}" ]; then
    echo "검색어를 입력해주세요. (예: $0 --search 대림)"
    safe_exit 1
  fi
  python3 -c "
import json
with open('${POI_LIST_FILE}', 'r', encoding='utf-8') as f:
    pois = json.load(f)
kw = '${KEYWORD}'
matches = [(c, n) for c, n in sorted(pois.items()) if kw in n or kw in c]
print(f'=== 서울시 핫스팟 검색 결과: \"{kw}\" (총 {len(matches)}건) ===')
if matches:
    for c, n in matches:
        print(f'  · [{c}] {n}')
else:
    print('  일치하는 핫스팟이 없습니다. ($0 --list 로 전체 목록을 확인하세요)')
"
  safe_exit 0
fi

# 프로젝트 루트의 .env 환경변수 로드
ENV_FILE="$(cd "${SCRIPT_DIR}/../.." && pwd)/.env"
if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  set +a
fi

API_KEY="${S_API_KEY:-${SEOUL_API_KEY:-76706545646f74743534576e594c47}}"

# 수집 대상 장소 배열 구성
AREAS=()
if [ $# -eq 0 ]; then
  # 인자가 없으면 강남권 주요 4대 핫스팟 기본 수집
  AREAS=("강남역" "역삼역" "선릉역" "신논현역·논현역")
else
  for arg in "$@"; do
    if [[ "$arg" == *","* ]]; then
      IFS=',' read -ra ADDR <<< "$arg"
      for sub in "${ADDR[@]}"; do
        trimmed="$(echo "$sub" | xargs)"
        [ -n "$trimmed" ] && AREAS+=("$trimmed")
      done
    else
      AREAS+=("$arg")
    fi
  done
fi

TOTAL_REQ=${#AREAS[@]}
echo "================================================================================"
echo "[INFO] 서울시 실시간 인구 데이터 수집 시작 (총 ${TOTAL_REQ}개 지역)"
echo "  - 대상 목록: ${AREAS[*]}"
echo "================================================================================"

TEMP_DIR="$(mktemp -d "${SCRIPT_DIR}/temp_seoul_XXXXXX")"
SUCCESS_FILES=()
SUCCESS_NAMES=()
FAIL_NAMES=()

# 각 지역별로 cURL 호출 및 유효성 검증
for area in "${AREAS[@]}"; do
  echo -n "[요청] '${area}' 조회 중... "
  URL="http://openapi.seoul.go.kr:8088/${API_KEY}/json/citydata_ppltn/1/5/${area}"
  TARGET_TMP="${TEMP_DIR}/$(echo "${area}" | sed 's/[^0-9A-Za-z가-힣]/_/g').json"

  if ! curl -s -g -m 10 "${URL}" > "${TARGET_TMP}" 2>/dev/null; then
    echo "✖ 실패 (네트워크 연결 오류)"
    FAIL_NAMES+=("${area} (네트워크 오류)")
    continue
  fi

  if grep -q "SeoulRtd.citydata_ppltn" "${TARGET_TMP}"; then
    SUCCESS_FILES+=("${TARGET_TMP}")
    SUCCESS_NAMES+=("${area}")
    # 인구 및 혼잡도 요약 파싱
    INFO_SUMMARY=$(python3 -c "
import json, sys
try:
    with open('${TARGET_TMP}', 'r', encoding='utf-8') as f:
        d = json.load(f)
    arr = d.get('SeoulRtd.citydata_ppltn', [])
    if arr:
        it = arr[0]
        cd = it.get('AREA_CD', '')
        lvl = it.get('AREA_CONGEST_LVL', '')
        pmin = it.get('AREA_PPLTN_MIN', '0')
        pmax = it.get('AREA_PPLTN_MAX', '0')
        print(f'✔ 성공 [{cd}] 혼잡도: {lvl} ({int(pmin):,}~{int(pmax):,}명)')
    else:
        print('✔ 성공')
except Exception:
    print('✔ 성공')
")
    echo "${INFO_SUMMARY}"
  else
    # 실패 원인 및 유사 지원 핫스팟 추천 파싱
    ERR_SUMMARY=$(python3 -c "
import json, difflib, os

area = '${area}'
poi_file = '${POI_LIST_FILE}'
pois = {}
if os.path.exists(poi_file):
    try:
        with open(poi_file, 'r', encoding='utf-8') as f:
            pois = json.load(f)
    except Exception:
        pass

name_to_code = {v: k for k, v in pois.items()}
poi_names = list(pois.values())

# 유사 핫스팟 매칭 (대방역 -> 대림역 등)
matches = difflib.get_close_matches(area, poi_names, n=2, cutoff=0.3)
if matches:
    recs = [f\"'{m}'({name_to_code.get(m, '')})\" for m in matches]
    print(f\"✖ 실패 (미지원 장소) ➔ 유사 핫스팟 추천: {', '.join(recs)}\")
else:
    print(f\"✖ 실패 (미지원 핫스팟: 서울시 119개 대상 목록에 없음)\")
")
    echo "${ERR_SUMMARY}"
    FAIL_NAMES+=("${area}")
  fi
done

SUCCESS_COUNT=${#SUCCESS_FILES[@]}

if [ "${SUCCESS_COUNT}" -eq 0 ]; then
  echo ""
  echo "[ERROR] 수집에 성공한 지역이 하나도 없습니다."
  echo "  - 실패 목록: ${FAIL_NAMES[*]}"
  echo "  - 안내: 서울시 실시간 인구 데이터는 지정된 119개 핫스팟만 지원합니다."
  echo "          지원 목록 확인: $0 --list  |  검색: $0 --search <단어>"
  rm -rf "${TEMP_DIR}"
  safe_exit 1
fi

# 수집 결과 통합 JSON 파일 및 하위 호환용 JSON 파일
OUTPUT_JSON="${SCRIPT_DIR}/seoul_ppltn.json"
COMPAT_JSON="${SCRIPT_DIR}/gangnam.json"

python3 -c "
import json, sys

success_paths = sys.argv[1:]
combined_items = []

for p in success_paths:
    try:
        with open(p, 'r', encoding='utf-8') as f:
            data = json.load(f)
        key = next((k for k in data.keys() if 'citydata_ppltn' in k), None)
        if key and data[key]:
            combined_items.extend(data[key])
    except Exception as e:
        pass

result_payload = {
    'SeoulRtd.citydata_ppltn': combined_items,
    'RESULT': {
        'RESULT.CODE': 'INFO-000',
        'RESULT.MESSAGE': f'정상 처리되었습니다. (총 {len(combined_items)}개 지역)'
    }
}

# 1) 메인 통합 JSON 저장 (수집된 모든 복수 지역 포함)
with open('${OUTPUT_JSON}', 'w', encoding='utf-8') as f:
    json.dump(result_payload, f, ensure_ascii=False, indent=2)

# 2) 하위 호환용 gangnam.json 파일 동기화 (기존 튜토리얼 스크립트 호환용, 모든 수집 지역 포함)
with open('${COMPAT_JSON}', 'w', encoding='utf-8') as f:
    json.dump(result_payload, f, ensure_ascii=False, indent=2)
" "${SUCCESS_FILES[@]}"

rm -rf "${TEMP_DIR}"

echo ""
echo "================================================================================"
echo "[SUCCESS] 복합 지역 실시간 인구 데이터 수집 완료 (${SUCCESS_COUNT}/${TOTAL_REQ}개 성공)"
echo "  - 메인 통합 JSON: ${OUTPUT_JSON} (총 ${SUCCESS_COUNT}개 지역 포함)"
echo "  - 하위 호환 JSON: ${COMPAT_JSON} (동일 복수 데이터 동기화)"
if [ ${#FAIL_NAMES[@]} -gt 0 ]; then
  echo "  - 제외된 지역:   ${FAIL_NAMES[*]}"
  echo "  - 팁: 지원되는 핫스팟 목록은 '$0 --list' 또는 '$0 --search <단어>'로 확인하세요."
fi
echo "================================================================================"

safe_exit 0
