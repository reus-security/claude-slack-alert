#!/usr/bin/env bash
# Claude Code Stop hook: Anthropic /api/oauth/usage 엔드포인트로 사용량을 직접 조회해
# ALERT_THRESHOLDS의 각 단계에 도달하면 Slack 알림.
#
# 환경변수 (~/.claude/hooks/usage-config.env):
#   SLACK_WEBHOOK_URL  : Slack Incoming Webhook
#   ALERT_THRESHOLDS   : 콤마 구분 % list (기본 "80,90")
#   ALERT_BUCKETS      : 모니터링할 bucket (기본 "five_hour,seven_day")
#                        값: five_hour, seven_day, seven_day_sonnet, seven_day_opus, ...
#
# Anthropic /usage 슬래시 커맨드와 1:1 동일한 데이터를 사용하므로 cap/weight calibration 불필요.

set -uo pipefail

MARKER_DIR="${HOME}/.claude/quota-markers"
LAST_CHECK="${MARKER_DIR}/last-check"
LOG_FILE="${MARKER_DIR}/last-run.log"
CREDS_FILE="${HOME}/.claude/.credentials.json"
THROTTLE_SEC=300
USAGE_ENDPOINT="https://api.anthropic.com/api/oauth/usage"

mkdir -p "$MARKER_DIR"

# 환경변수 config 파일 fallback (Claude Code subprocess는 ~/.bashrc 안 읽음)
CONFIG_FILE="${HOME}/.claude/hooks/usage-config.env"
if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
  [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE"
fi

: "${ALERT_THRESHOLDS:=80,90}"
: "${ALERT_BUCKETS:=five_hour,seven_day}"

# stdin (hook payload) 비우기
if [[ ! -t 0 ]]; then
  cat >/dev/null 2>&1 || true
fi

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
}

# 5분 throttle
if [[ -f "$LAST_CHECK" ]]; then
  age=$(( $(date +%s) - $(stat -c %Y "$LAST_CHECK" 2>/dev/null || echo 0) ))
  if (( age < THROTTLE_SEC )); then
    log "throttled (age=${age}s)"
    exit 0
  fi
fi
touch "$LAST_CHECK"

# 환경변수 / 의존성 검증
if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
  log "skip: SLACK_WEBHOOK_URL 미설정"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  log "skip: jq not installed"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  log "skip: curl not installed"
  exit 0
fi
if [[ ! -f "$CREDS_FILE" ]]; then
  log "skip: credentials 파일 없음 ($CREDS_FILE) — Claude Code 로그인 필요"
  exit 0
fi

# OAuth token 추출
TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDS_FILE" 2>/dev/null)
EXPIRES_AT=$(jq -r '.claudeAiOauth.expiresAt // 0' "$CREDS_FILE" 2>/dev/null)
if [[ -z "$TOKEN" ]]; then
  log "skip: OAuth accessToken을 읽을 수 없음"
  exit 0
fi
# expiresAt은 ms 단위 epoch
NOW_MS=$(( $(date +%s) * 1000 ))
if [[ "$EXPIRES_AT" =~ ^[0-9]+$ ]] && (( EXPIRES_AT > 0 && EXPIRES_AT < NOW_MS )); then
  log "skip: OAuth token 만료됨 (expired at $(date -d "@$(( EXPIRES_AT / 1000 ))" '+%Y-%m-%d %H:%M:%S')) — Claude Code 재로그인 필요"
  exit 0
fi

# threshold list 파싱 + 오름차순 정렬 (중복 제거)
IFS=',' read -r -a THRESHOLDS_ARR <<< "$ALERT_THRESHOLDS"
mapfile -t THRESHOLDS_SORTED < <(printf '%s\n' "${THRESHOLDS_ARR[@]}" | grep -E '^[0-9]+$' | sort -n -u)
if (( ${#THRESHOLDS_SORTED[@]} == 0 )); then
  THRESHOLDS_SORTED=(80)
fi

# bucket list 파싱
IFS=',' read -r -a BUCKETS_ARR <<< "$ALERT_BUCKETS"

# /api/oauth/usage 호출
RESP_FILE=$(mktemp)
trap 'rm -f "$RESP_FILE"' EXIT

HTTP_CODE=$(curl -sS --max-time 15 \
  -o "$RESP_FILE" -w "%{http_code}" \
  -H "Authorization: Bearer $TOKEN" \
  -H "anthropic-beta: oauth-2025-04-20" \
  -H "Accept: application/json" \
  "$USAGE_ENDPOINT" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" != "200" ]]; then
  log "skip: /api/oauth/usage HTTP $HTTP_CODE — 토큰 만료/네트워크 문제 (응답: $(head -c 200 "$RESP_FILE" 2>/dev/null))"
  exit 0
fi

USAGE_JSON=$(cat "$RESP_FILE")
if ! echo "$USAGE_JSON" | jq -e . >/dev/null 2>&1; then
  log "skip: /api/oauth/usage 응답이 JSON 아님 (응답: $(head -c 200 "$RESP_FILE" 2>/dev/null))"
  exit 0
fi

# bucket 라벨 매핑 (한국어)
bucket_label() {
  case "$1" in
    five_hour)              echo "세션(5h)" ;;
    seven_day)              echo "주간(전체)" ;;
    seven_day_sonnet)       echo "주간(Sonnet)" ;;
    seven_day_opus)         echo "주간(Opus)" ;;
    seven_day_oauth_apps)   echo "주간(OAuth Apps)" ;;
    seven_day_cowork)       echo "주간(Cowork)" ;;
    seven_day_omelette)     echo "주간(Omelette)" ;;
    *)                      echo "$1" ;;
  esac
}

# 임계값별 아이콘
# 90% 이상 → 🚨 (긴급), 70% 이상 → ⚠️ (경고), 그 외 → 🔔 (정보)
pct_icon() {
  local p="${1:-0}"
  if (( p >= 90 )); then
    echo "🚨"
  elif (( p >= 70 )); then
    echo "⚠️"
  else
    echo "🔔"
  fi
}

send_slack() {
  local text="$1" body code
  body=$(jq -nc --arg t "$text" '{text: $t}')
  code=$(curl -sS --max-time 10 -o /dev/null -w "%{http_code}" \
    -X POST "$SLACK_WEBHOOK_URL" \
    -H 'Content-Type: application/json' --data "$body" 2>/dev/null || echo "000")
  if [[ "$code" == "200" ]]; then
    return 0
  elif [[ "$code" == "404" || "$code" == "410" ]]; then
    log "slack post failed: HTTP $code — webhook URL 폐기/잘못됨. usage-config.env 확인"
    return 1
  else
    log "slack post failed: HTTP $code"
    return 1
  fi
}

# 분 단위를 한국어 가독형으로
fmt_remaining() {
  local mins="${1:-}"
  [[ -z "$mins" || ! "$mins" =~ ^-?[0-9]+$ ]] && { echo ""; return; }
  (( mins < 0 )) && { echo "(만료됨)"; return; }
  if (( mins >= 1440 )); then
    printf "%d일 %d시간" $(( mins / 1440 )) $(( (mins % 1440) / 60 ))
  elif (( mins >= 60 )); then
    printf "%d시간 %d분" $(( mins / 60 )) $(( mins % 60 ))
  else
    printf "%d분" "$mins"
  fi
}

# ISO 8601 → epoch
iso_to_epoch() {
  date -u -d "$1" +%s 2>/dev/null
}

now_epoch=$(date -u +%s)

# 로그 한 줄에 모든 bucket 요약
LOG_PARTS=()
for b in "${BUCKETS_ARR[@]}"; do
  pct=$(echo "$USAGE_JSON" | jq -r --arg b "$b" '.[$b].utilization // empty')
  if [[ -n "$pct" && "$pct" != "null" ]]; then
    LOG_PARTS+=("${b}=${pct}%")
  else
    LOG_PARTS+=("${b}=n/a")
  fi
done
log "usage: $(IFS=', '; echo "${LOG_PARTS[*]}"), thresholds=[$(IFS=,; echo "${THRESHOLDS_SORTED[*]}")]"

# 각 bucket × threshold 조합 검사
for bucket in "${BUCKETS_ARR[@]}"; do
  pct=$(echo "$USAGE_JSON" | jq -r --arg b "$bucket" '.[$b].utilization // empty')
  resets_at=$(echo "$USAGE_JSON" | jq -r --arg b "$bucket" '.[$b].resets_at // empty')

  # bucket이 응답에 없거나 null이면 스킵
  if [[ -z "$pct" || "$pct" == "null" ]]; then
    continue
  fi
  if ! [[ "$pct" =~ ^[0-9]+$ ]]; then
    log "warn: ${bucket}.utilization 정수 아님 ($pct) — skip"
    continue
  fi

  label=$(bucket_label "$bucket")

  # marker_id: resets_at의 분 단위까지만 사용 (microsecond는 매 호출마다 변함 → dedup 깨짐 방지)
  # ISO 8601 "2026-05-08T03:40:00.923131+00:00" → epoch → 분 단위 round → "epoch-29636334"
  if [[ -n "$resets_at" && "$resets_at" != "null" ]]; then
    end_epoch_for_marker=$(iso_to_epoch "$resets_at")
    if [[ "$end_epoch_for_marker" =~ ^[0-9]+$ ]]; then
      marker_id="epoch-$(( end_epoch_for_marker / 60 ))"
    else
      marker_id="unknown"
    fi
  else
    marker_id="unknown"
  fi

  # 남은 시간 계산
  remaining_min=""
  remain_str=""
  if [[ -n "$resets_at" && "$resets_at" != "null" ]]; then
    end_epoch=$(iso_to_epoch "$resets_at")
    if [[ "$end_epoch" =~ ^[0-9]+$ ]] && (( end_epoch > now_epoch )); then
      remaining_min=$(( (end_epoch - now_epoch) / 60 ))
      remain_fmt=$(fmt_remaining "$remaining_min")
      [[ -n "$remain_fmt" ]] && remain_str=" — ${remain_fmt} 뒤 리셋"
    fi
  fi

  # Pass 1: 마커 없는 초과 임계값 중 가장 높은 것 찾기
  # (여러 임계값이 동시에 초과된 경우 가장 높은 것 하나만 알람 발송)
  highest_new=""
  for threshold in "${THRESHOLDS_SORTED[@]}"; do
    marker="${MARKER_DIR}/${bucket}-${threshold}pct-${marker_id}"
    if (( pct >= threshold )) && [[ ! -f "$marker" ]]; then
      highest_new="$threshold"
    fi
  done

  # Pass 2: highest_new만 알람, 나머지는 silent marker 생성
  for threshold in "${THRESHOLDS_SORTED[@]}"; do
    marker="${MARKER_DIR}/${bucket}-${threshold}pct-${marker_id}"
    if (( pct >= threshold )); then
      if [[ ! -f "$marker" ]]; then
        if [[ "$threshold" == "$highest_new" ]]; then
          # 가장 높은 임계값만 알람 발송
          icon=$(pct_icon "$threshold")
          if send_slack "${icon} Claude Code ${label} 사용량 ${pct}% 도달${remain_str} [임계 ${threshold}%]"; then
            touch "$marker"
            log "alert sent: ${bucket} ${pct}% (threshold=${threshold}%)${remain_str}"
          else
            log "alert NOT sent (slack failure); marker not created — will retry: ${bucket} threshold=${threshold}%"
          fi
        else
          # 이미 지나친 낮은 임계값 → 알람 없이 마커만 생성
          touch "$marker"
          log "silent marker: ${bucket} ${pct}% already past ${threshold}% — no alert"
        fi
      fi
    else
      # 사용량이 threshold 아래면 marker 삭제 (다음 윈도우에서 재발사 가능)
      rm -f "$marker"
    fi
  done
done

exit 0
