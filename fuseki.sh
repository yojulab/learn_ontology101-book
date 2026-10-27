#!/usr/bin/env bash
# ==============================================================================
# Apache Jena Fuseki Server 관리 스크립트 (fuseki.sh)
# ==============================================================================
# Usage:
#   ./fuseki.sh status          # 상태 확인
#   ./fuseki.sh start           # 서비스 시작 (포트: 3030)
#   ./fuseki.sh stop            # 서비스 중지
#   ./fuseki.sh restart         # 서비스 재시작
#   ./fuseki.sh logs [N]        # 실행 로그 확인 (기본: 50줄, -f 옵션 가능)
#   ./fuseki.sh load-ch01       # ch01 강남역 TTL 데이터 적재
# ==============================================================================

set -euo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SCRIPT_SOURCE" ]; do
  _DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"
  SCRIPT_SOURCE="$(readlink "$SCRIPT_SOURCE")"
  [[ $SCRIPT_SOURCE != /* ]] && SCRIPT_SOURCE="$_DIR/$SCRIPT_SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SCRIPT_SOURCE")" && pwd)"

# 프로젝트 루트 .env 환경변수 로드
if [ -f "$SCRIPT_DIR/.env" ]; then
  set -a
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/.env"
  set +a
fi

FUSEKI_HOME="${FUSEKI_HOME:-/opt/fuseki}"
FUSEKI_BASE="${FUSEKI_BASE:-/opt/fuseki/run}"
FUSEKI_PORT="${FUSEKI_PORT:-3030}"
FUSEKI_URL="http://localhost:${FUSEKI_PORT}"
PID_FILE="/var/run/fuseki.pid"
LOG_FILE="/var/log/fuseki.log"

export FUSEKI_HOME FUSEKI_BASE

log()  { printf '\033[1;36m[fuseki]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; }

is_running() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      return 0
    fi
  fi
  if curl -s -m 2 "$FUSEKI_URL/\$/ping" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

get_pid() {
  if [ -f "$PID_FILE" ]; then
    local pid
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      echo "$pid"
      return 0
    fi
  fi
  pgrep -f "fuseki-server" | head -1 || true
}

cmd_start() {
  if is_running; then
    log "Fuseki 서버가 이미 실행 중입니다. (포트: $FUSEKI_PORT, PID: $(get_pid))"
    cmd_status
    return 0
  fi

  [ -x "$FUSEKI_HOME/fuseki-server" ] || {
    err "Fuseki 실행 파일을 찾을 수 없습니다: $FUSEKI_HOME/fuseki-server"
    exit 1
  }

  log "Apache Jena Fuseki 서버를 시작합니다... (포트: $FUSEKI_PORT)"
  log "  - FUSEKI_HOME: $FUSEKI_HOME"
  log "  - FUSEKI_BASE: $FUSEKI_BASE"

  mkdir -p "$FUSEKI_BASE/logs" "$FUSEKI_BASE/databases" /var/run /var/log

  nohup "$FUSEKI_HOME/fuseki-server" --port="$FUSEKI_PORT" > "$LOG_FILE" 2>&1 < /dev/null &
  local new_pid=$!
  echo "$new_pid" > "$PID_FILE"

  log "초기화 대기 중 (PID: $new_pid)..."
  local started=0
  for _ in $(seq 1 20); do
    if curl -s -m 2 "$FUSEKI_URL/\$/ping" >/dev/null 2>&1; then
      started=1
      break
    fi
    sleep 1
  done

  if [ "$started" -eq 1 ]; then
    log "Fuseki 서버가 정상 기동되었습니다!"
    echo ""
    cmd_status
  else
    err "20초 내에 Fuseki 서버가 응답하지 않았습니다. 로그를 확인하세요 ($LOG_FILE):"
    tail -n 25 "$LOG_FILE" >&2 || true
    return 1
  fi
}

cmd_stop() {
  local pid
  pid="$(get_pid)"

  if [ -z "$pid" ] && ! curl -s -m 2 "$FUSEKI_URL/\$/ping" >/dev/null 2>&1; then
    log "Fuseki 서버가 현재 실행 중이지 않습니다."
    rm -f "$PID_FILE"
    return 0
  fi

  log "Fuseki 서버를 중지합니다 (PID: ${pid:-알수없음})..."
  if [ -n "$pid" ]; then
    kill "$pid" 2>/dev/null || true
  else
    pkill -f "fuseki-server" 2>/dev/null || true
  fi

  for _ in $(seq 1 10); do
    if ! curl -s -m 1 "$FUSEKI_URL/\$/ping" >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    warn "정상 종료 대기 초과 → 강제 종료(SIGKILL)를 수행합니다."
    kill -9 "$pid" 2>/dev/null || true
  fi

  rm -f "$PID_FILE"
  log "Fuseki 서버가 중지되었습니다."
}

cmd_restart() {
  cmd_stop
  sleep 1
  cmd_start
}

cmd_status() {
  local pid
  pid="$(get_pid)"
  if curl -s -m 2 "$FUSEKI_URL/\$/ping" >/dev/null 2>&1; then
    printf '\033[1;32m● Fuseki 상태: 실행 중 (RUNNING)\033[0m\n'
    echo "  - 웹 UI 주소:   $FUSEKI_URL"
    echo "  - 프로세스 PID: ${pid:-알수없음}"
    echo "  - 설정 경로:    $FUSEKI_BASE"
    echo "  - 로그 파일:    $LOG_FILE"
    echo ""
    echo "  [등록된 데이터셋]"
    local datasets
    datasets=$(curl -s "$FUSEKI_URL/\$/datasets" 2>/dev/null | grep -o '"ds.name"[^,]*' | cut -d'"' -f4 || true)
    if [ -n "$datasets" ]; then
      for ds in $datasets; do
        echo "    * $ds"
        echo "        SPARQL Query : $FUSEKI_URL$ds/query  (또는 $ds/sparql)"
        echo "        SPARQL Update: $FUSEKI_URL$ds/update"
        echo "        Graph Store  : $FUSEKI_URL$ds/data"
      done
    else
      echo "    (등록된 데이터셋 없음)"
    fi
  else
    printf '\033[1;31m○ Fuseki 상태: 중지됨 (STOPPED)\033[0m\n'
    return 3
  fi
}

cmd_logs() {
  local lines="${1:-50}"
  if [ ! -f "$LOG_FILE" ]; then
    err "로그 파일이 존재하지 않습니다: $LOG_FILE"
    return 1
  fi

  if [ "${lines}" = "-f" ]; then
    tail -n 50 -f "$LOG_FILE"
  else
    tail -n "$lines" "$LOG_FILE"
  fi
}

cmd_load_ch01() {
  if ! is_running; then
    err "Fuseki 서버가 실행 중이지 않습니다. 먼저 './fuseki.sh start'를 실행하세요."
    return 1
  fi

  local ttl_file="$SCRIPT_DIR/ch01-oag/convert/gangnam.ttl"
  if [ ! -f "$ttl_file" ]; then
    err "gangnam.ttl 파일이 없습니다: $ttl_file"
    return 1
  fi

  log "ch01 강남역 TTL 데이터를 /fc Named Graph(http://k.fc/onto)에 적재합니다..."
  local res
  res=$(curl -s -w "\nHTTP_STATUS:%{http_code}" -X POST -H 'Content-Type: text/turtle' \
    --data-binary @"$ttl_file" \
    "$FUSEKI_URL/fc/data?graph=http://k.fc/onto")

  local http_code
  http_code=$(echo "$res" | grep "HTTP_STATUS:" | cut -d':' -f2)
  if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
    log "적재 완료! (HTTP $http_code)"
  else
    err "적재 실패 (HTTP $http_code)"
    echo "$res"
    return 1
  fi
}

usage() {
  cat << EOF
Apache Jena Fuseki 관리 스크립트

사용법:
  $0 status          # 상태 확인
  $0 start           # 서비스 시작
  $0 stop            # 서비스 중지
  $0 restart         # 서비스 재시작
  $0 logs [50|-f]    # 실행 로그 확인 (기본: 50줄, -f: 실시간 추적)
  $0 load-ch01       # ch01 강남역 TTL 데이터 적재 (http://k.fc/onto)

EOF
}

case "${1:-status}" in
  status)    cmd_status ;;
  start)     cmd_start ;;
  stop)      cmd_stop ;;
  restart)   cmd_restart ;;
  logs)      shift; cmd_logs "${1:-50}" ;;
  load-ch01) cmd_load_ch01 ;;
  help|--help|-h) usage ;;
  *)
    usage
    exit 1
    ;;
esac
