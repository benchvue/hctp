/**
 * HCTP 방문자 카운터 (Google Apps Script)
 * ─────────────────────────────────────────────
 * 설치 (5분, 1회):
 *  1. https://script.google.com → New project
 *  2. 이 코드 전체를 붙여넣고 저장 (프로젝트 이름: hctp-visitors)
 *  3. Deploy → New deployment → 톱니에서 "Web app" 선택
 *       - Execute as: Me
 *       - Who has access: Anyone          ← 중요!
 *  4. Deploy → 나오는 Web app URL(…/exec) 복사
 *  5. index.html 과 upload.html 의 STATS_URL 에 붙여넣기
 *
 * 동작:
 *  - GET (파라미터 없음)  → 오늘 날짜(미국 동부 기준) 카운트 +1
 *  - GET ?stats=1        → { "2026-08-24": 12, ... } 전체 일별 데이터 반환
 *  - 데이터는 Script Properties 에 저장 (날짜당 1키, 5년치도 여유)
 */

function doGet(e) {
  var p = (e && e.parameter) || {};

  if (p.stats) {
    return json_(PropertiesService.getScriptProperties().getProperties());
  }

  // 방문 1회 기록 (동시 접속 유실 방지 락)
  var day = Utilities.formatDate(new Date(), "America/New_York", "yyyy-MM-dd");
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(3000);
    var props = PropertiesService.getScriptProperties();
    props.setProperty(day, String(Number(props.getProperty(day) || 0) + 1));
  } catch (err) {
    // 락 실패 시 이번 방문은 건너뜀 (통계용이므로 허용)
  } finally {
    try { lock.releaseLock(); } catch (e2) {}
  }
  return json_({ ok: 1 });
}

function json_(obj) {
  return ContentService
    .createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
