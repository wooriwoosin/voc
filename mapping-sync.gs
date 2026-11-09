/**
 * VOC 대시보드 — 업체 매핑 공유 저장소 (Google Apps Script)
 *
 * 설치: 구글 시트 > 확장 프로그램 > Apps Script 에 이 파일 내용을 붙여넣고
 *       배포 > 새 배포 > 웹 앱 (실행: 나, 액세스: 모든 사용자) 로 배포.
 *       나온 웹 앱 URL(…/exec)을 대시보드 index.html 의 MAP_API 에 넣으면 됩니다.
 *
 * 저장 형태: '매핑' 시트 — A열 대표명, B열부터 같은 업체로 묶을 이름들 (시트에서 직접 수정 가능)
 *            '변경기록' 시트 — 언제 어떤 변경이 있었는지 (되돌릴 때 참고)
 */
const MAP_SHEET = '매핑';
const LOG_SHEET = '변경기록';

function doGet() {
  return out_({ ok: true, mapping: readMapping_(), updatedAt: lastUpdated_() });
}

function doPost(e) {
  const lock = LockService.getScriptLock();
  lock.waitLock(20000); // 여러 명이 동시에 저장해도 순서대로 처리
  try {
    const req = JSON.parse(e.postData.contents);
    let m = readMapping_();
    const lc = s => String(s).trim().toLowerCase();

    if (req.op === 'add') {
      const c = String(req.c || '').trim();
      const a = (req.a || []).map(x => String(x).trim()).filter(Boolean);
      if (!c || !a.length) throw new Error('대표명과 이름이 필요합니다');
      const ex = m.find(x => lc(x.c) === lc(c));
      if (ex) a.forEach(x => { if (!ex.a.some(y => lc(y) === lc(x))) ex.a.push(x); });
      else m.push({ c, a });
    } else if (req.op === 'del') {
      m = m.filter(x => lc(x.c) !== lc(req.c));
    } else if (req.op === 'replace' || (req.op === 'init' && !m.length)) {
      if (!valid_(req.mapping)) throw new Error('매핑 형식 오류');
      m = req.mapping;
    } else if (req.op !== 'init') {
      throw new Error('알 수 없는 요청: ' + req.op);
    }

    if (req.op !== 'init' || !readMapping_().length) {
      writeMapping_(m);
      log_(req);
    }
    return out_({ ok: true, mapping: readMapping_(), updatedAt: lastUpdated_() });
  } catch (err) {
    return out_({ ok: false, error: String(err.message || err) });
  } finally {
    lock.releaseLock();
  }
}

function sheet_(name) {
  const ss = SpreadsheetApp.getActiveSpreadsheet();
  return ss.getSheetByName(name) || ss.insertSheet(name);
}

function readMapping_() {
  const v = sheet_(MAP_SHEET).getDataRange().getDisplayValues();
  return v.filter((r, i) => !(i === 0 && r[0] === '대표명'))
    .map(r => ({ c: String(r[0]).trim(), a: r.slice(1).map(x => String(x).trim()).filter(Boolean) }))
    .filter(x => x.c);
}

function writeMapping_(m) {
  const sh = sheet_(MAP_SHEET);
  sh.clearContents();
  const w = Math.max(2, ...m.map(x => x.a.length + 1));
  const rows = [['대표명', '같은 업체 이름들 →'].concat(Array(w - 2).fill(''))]
    .concat(m.map(x => [x.c].concat(x.a, Array(w - 1 - x.a.length).fill(''))));
  sh.getRange(1, 1, rows.length, w).setNumberFormat('@').setValues(rows);
  sh.getRange(1, 1, 1, w).setFontWeight('bold');
  sh.setFrozenRows(1);
}

function log_(req) {
  const sh = sheet_(LOG_SHEET);
  if (!sh.getLastRow()) sh.appendRow(['시각', '작업', '내용']);
  const what = req.op === 'add' ? req.c + ' ← ' + (req.a || []).join(', ')
    : req.op === 'del' ? req.c
    : (req.mapping || []).length + '개 그룹';
  sh.appendRow([new Date(), req.op, what]);
}

function lastUpdated_() {
  const sh = sheet_(LOG_SHEET), n = sh.getLastRow();
  if (n < 2) return null;
  const d = sh.getRange(n, 1).getValue();
  return d instanceof Date ? d.toISOString() : null;
}

function valid_(m) {
  return Array.isArray(m) && m.every(x => x && typeof x.c === 'string' && x.c.trim() && Array.isArray(x.a));
}

function out_(o) {
  return ContentService.createTextOutput(JSON.stringify(o)).setMimeType(ContentService.MimeType.JSON);
}
