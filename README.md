# Claude Code 사용량 알림 시스템

Claude Code 세션(5h) / 주간(7d) 사용량이 임계값에 도달하면 Slack으로 자동 알림.

---

## 구조 한눈에 보기

```
~/.claude/
├── settings.json                    ← Stop hook 등록 (응답 종료마다 자동 실행)
├── hooks/
│   ├── check-usage-quota.sh         ← 메인 스크립트
│   ├── usage-config.env             ← 설정 (webhook URL, 임계값, 모니터링 bucket)
│   └── README.md                    ← 이 문서
└── quota-markers/
    ├── last-check                   ← throttle 타임스탬프 (5분 throttle)
    ├── last-run.log                 ← 실행 로그
    └── {bucket}-{threshold}pct-epoch-{N}   ← dedup 마커 (알람 중복 방지)

crontab
└── */5 * * * * bash ~/.claude/hooks/check-usage-quota.sh < /dev/null
                                     ← 5분마다 백그라운드 자동 체크
```

---

## 트리거 2종 (둘 다 같은 스크립트 호출)

| 트리거 | 시점 | 용도 |
|---|---|---|
| **Stop hook** (`settings.json`) | Claude 응답이 끝날 때마다 | 대화 중 실시간 체크 |
| **cron** (`*/5 * * * *`) | 5분마다 백그라운드 | 대화 안 할 때도 모니터링 |

5분 throttle이 중복 API 호출을 자동 차단해서 두 트리거가 충돌 없이 공존.

---

## 동작 흐름

```
트리거 (Stop hook 또는 cron)
      ↓
check-usage-quota.sh
      ↓
5분 throttle 체크 → (throttle 중이면 즉시 종료)
      ↓
~/.claude/.credentials.json 에서 OAuth accessToken 추출
      ↓
GET https://api.anthropic.com/api/oauth/usage
  Authorization: Bearer {token}
  anthropic-beta: oauth-2025-04-20
      ↓
응답 JSON에서 bucket별 utilization(%) 파싱
      ↓
[Pass 1] 마커 없는 초과 임계값 중 가장 높은 것 찾기 (highest_new)
[Pass 2] 각 bucket × threshold 검사
  ├─ pct >= threshold AND 마커 없음
  │     ├─ threshold == highest_new → 아이콘 결정 + Slack 발송 + 마커 생성
  │     └─ 그 외 (이미 지나친 낮은 임계값) → silent 마커만 생성 (알람 X)
  └─ pct < threshold → 마커 삭제 (다음 윈도우 재알람 가능)
      ↓
종료
```

---

## 설정 파일 (`usage-config.env`)

```bash
# Slack Incoming Webhook URL
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."

# 알람 임계값 (%, 콤마 구분 → 오름차순 자동 정렬)
# 예: "80,90"                                → 2단계
# 예: "10,20,30,40,50,60,70,80,90,100"       → 10% 단위 10단계
export ALERT_THRESHOLDS="10,20,30,40,50,60,70,80,90,100"

# 모니터링할 quota bucket (콤마 구분)
# 가능한 값: five_hour, seven_day, seven_day_sonnet, seven_day_opus,
#           seven_day_oauth_apps, seven_day_cowork, seven_day_omelette
export ALERT_BUCKETS="five_hour,seven_day"
```

> ⚠️ `~/.bashrc`가 아닌 이 파일에서만 설정해야 함.
> Claude Code 서브프로세스와 cron 모두 `~/.bashrc`를 읽지 않음.

---

## 알람 아이콘 (severity 차등)

임계값에 따라 Slack 메시지 첫 글자 아이콘이 다르게 출력됨.

| 임계값 범위 | 아이콘 | 의미 |
|---|---|---|
| 90% 이상 | 🚨 | 긴급 (위험) |
| 70~80% | ⚠️ | 경고 (주의) |
| 10~60% | 🔔 | 정보 (안전 영역) |

예시:
```
🔔 Claude Code 주간(전체) 사용량 32% 도달 — 3일 7시간 뒤 리셋 [임계 30%]
⚠️ Claude Code 세션(5h) 사용량 72% 도달 — 1시간 50분 뒤 리셋 [임계 70%]
🚨 Claude Code 세션(5h) 사용량 95% 도달 — 30분 뒤 리셋 [임계 90%]
```

---

## 데이터 소스

| 항목 | 내용 |
|------|------|
| **엔드포인트** | `https://api.anthropic.com/api/oauth/usage` |
| **인증** | `~/.claude/.credentials.json` 의 OAuth accessToken |
| **데이터** | `/usage` 슬래시 커맨드와 100% 동일 (서버 직접 반환) |
| **토큰 소모** | 없음 — 계정 관리 API (AI 추론 없음, 무과금) |

응답 예시:
```json
{
  "five_hour":    { "utilization": 11, "resets_at": "2026-05-08T03:40:00+00:00" },
  "seven_day":    { "utilization": 57, "resets_at": "2026-05-11T09:00:00+00:00" },
  "seven_day_sonnet": { "utilization": 7, "resets_at": "..." }
}
```

---

## 중복 알람 방지 (dedup) + Catch-up Blast 방지

### 마커 파일 규칙

```
~/.claude/quota-markers/{bucket}-{threshold}pct-epoch-{resets_at_epoch/60}
```

예시:
```
five_hour-80pct-epoch-29637866
seven_day-90pct-epoch-29652240
```

- `resets_at`를 **분 단위 epoch**으로 변환 → 동일 윈도우 안에서 항상 같은 마커 ID
  (초 이하 microsecond drift 방지)
- 임계값별로 별도 마커 → 80% 도달 시 1회, 90% 도달 시 1회 독립 발송
- 윈도우 리셋 후 (`resets_at` 변경) → 새 마커 파일 → 다음 윈도우에서 재알람

### Two-Pass 알람 발송 (Catch-up Blast 방지)

**문제 시나리오**: 임계값을 `10,20,30,40,50,60,70,80,90,100`으로 설정했는데 현재 사용량이 이미 58%라면, naive 구현은 10/20/30/40/50% 알람을 동시에 5개 발사함.

**해결**:
1. **Pass 1** — 현재 사용량을 초과하면서 마커 없는 임계값 중 **가장 높은 것**(`highest_new`)만 찾기
2. **Pass 2** — `highest_new`만 Slack 발송, 나머지(이미 지나친 낮은 임계값)는 **silent 마커**만 생성

### 동작 시나리오 예시

| 사용량 변화 | Slack 알람 | 비고 |
|---|---|---|
| 처음 시작, 사용량 22% | 🔔 [임계 20%] 1개 | 10%는 silent |
| 사용량 → 31% | 🔔 [임계 30%] 1개 | |
| 사용량 → 71% | ⚠️ [임계 70%] 1개 | 40/50/60% 마커는 그대로 |
| 사용량 → 91% | 🚨 [임계 90%] 1개 | |
| 새 5h 윈도우 시작 (0%) | 마커 자동 삭제 | 다시 10%부터 계단식 |

### throttle

- `last-check` 파일의 mtime 기준 **5분** 이내 재실행 시 즉시 종료 (중복 API 호출 방지)
- Stop hook + cron 동시 트리거 시에도 throttle이 충돌 방지

---

## 로그 확인

```bash
tail -f ~/.claude/quota-markers/last-run.log
```

정상 로그 예시:
```
[2026-05-08 01:39:48] usage: five_hour=22%,seven_day=59%, thresholds=[10,20,...,100]
[2026-05-08 01:39:48] silent marker: five_hour 22% already past 10% — no alert
[2026-05-08 01:39:48] alert sent: five_hour 22% (threshold=20%) — 2시간 0분 뒤 리셋
[2026-05-08 01:39:49] alert sent: seven_day 59% (threshold=50%) — 3일 7시간 뒤 리셋
[2026-05-08 01:42:01] throttled (age=133s)
```

에러 로그 예시:
```
[...] skip: OAuth token 만료됨 — Claude Code 재로그인 필요
[...] slack post failed: HTTP 404 — webhook URL 폐기/잘못됨. usage-config.env 확인
[...] skip: jq not installed
```

---

## Cron 등록 (백그라운드 자동 체크)

대화 여부와 무관하게 5분마다 체크하려면:

```bash
crontab -e
```

다음 한 줄 추가:
```cron
*/5 * * * * bash /home/wny/.claude/hooks/check-usage-quota.sh < /dev/null
```

확인:
```bash
crontab -l | grep check-usage-quota
```

---

## 테스트 방법

### 1) Webhook 연결 확인
```bash
source ~/.claude/hooks/usage-config.env
curl -sS -o /dev/null -w "%{http_code}\n" \
  -X POST "$SLACK_WEBHOOK_URL" \
  -H 'Content-Type: application/json' \
  --data '{"text":"webhook 테스트 ✅"}'
# 기대: 200
```

### 2) 아이콘 미리보기 (3가지 severity)
```bash
source ~/.claude/hooks/usage-config.env
for t in 30 70 90; do
  if (( t >= 90 )); then icon="🚨"; elif (( t >= 70 )); then icon="⚠️"; else icon="🔔"; fi
  body=$(jq -nc --arg t "${icon} 테스트 — 임계 ${t}%" '{text: $t}')
  curl -sS -o /dev/null -w "임계 ${t}%: HTTP %{http_code}\n" \
    -X POST "$SLACK_WEBHOOK_URL" -H 'Content-Type: application/json' --data "$body"
done
```

### 3) 알람 강제 발동 (마커 초기화 후 즉시 실행)
```bash
rm -f ~/.claude/quota-markers/*pct* ~/.claude/quota-markers/last-check
bash ~/.claude/hooks/check-usage-quota.sh < /dev/null
tail -10 ~/.claude/quota-markers/last-run.log
# → 현재 사용량의 가장 높은 임계값 1개씩 (bucket별로) 알람
```

### 4) dedup 확인 (즉시 재실행)
```bash
rm -f ~/.claude/quota-markers/last-check
bash ~/.claude/hooks/check-usage-quota.sh < /dev/null
# → 마커가 이미 있으므로 추가 알람 0개
```

---

## 설정 변경 방법

`~/.claude/hooks/usage-config.env` 수정 후 **재시작 불필요** (다음 hook/cron 실행 시 즉시 반영).

```bash
# 단순 80/90 2단계
export ALERT_THRESHOLDS="80,90"

# 10% 단위 정밀 모니터링
export ALERT_THRESHOLDS="10,20,30,40,50,60,70,80,90,100"

# Sonnet 별도 모니터링 추가
export ALERT_BUCKETS="five_hour,seven_day,seven_day_sonnet"
```

> 임계값 list를 변경하면 새로 추가된 낮은 임계값은 자동으로 silent 마커 처리됨 (catch-up blast 방지).

---

## 의존성

| 도구 | 용도 | 설치 확인 |
|------|------|----------|
| `curl` | API 호출 / Slack 발송 | `which curl` |
| `jq` | JSON 파싱 | `which jq` |
| `bash 4+` | `mapfile`, `(( ))` | `bash --version` |
| `date` (GNU) | ISO 8601 파싱 | Linux 기본 탑재 |
| `cron` | 백그라운드 5분 체크 (선택) | `systemctl status cron` |

---

## 문제 해결

| 증상 | 원인 | 해결 |
|------|------|------|
| 알람이 전혀 안 옴 | webhook 404 or `SLACK_WEBHOOK_URL` 미설정 | 로그 확인 → Slack에서 webhook 재생성 → `usage-config.env` 업데이트 |
| 한 번에 여러 알람 폭주 | 마커 없는 상태에서 임계값 list 변경 | 정상 동작 (highest_new 1개만 발송) — log에 `silent marker` 다수 |
| 같은 윈도우에서 알람 반복 | 마커 파일 손상 | `rm -f ~/.claude/quota-markers/*pct*` |
| `/usage`와 % 불일치 | (구버전) ccusage 토큰 합산 방식 차이 | 현재 버전은 OAuth API 직접 호출로 해결됨 |
| token 만료 에러 | OAuth 토큰 만료 | Claude Code 재로그인 (`/login`) |
| 대화 중인데 로그 안 찍힘 | throttle 정상 동작 | 5분에 한 번만 실제 체크 — 정상 |
| 대화 안 하는데 로그 안 찍힘 | cron 미등록 | `crontab -l`로 확인, 위 §Cron 등록 참조 |
