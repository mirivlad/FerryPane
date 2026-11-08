import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Builds a single, offline, searchable SMS archive. Untrusted message text
/// never becomes markup or JavaScript; it is encoded into a base64 payload
/// and displayed exclusively with DOM textContent.
class SmsArchive {
  static Future<String> createViewer(File jsonFile) async {
    final raw = await jsonFile.readAsBytes();
    if (raw.length > 150 * 1024 * 1024) {
      throw const FormatException('Архив SMS превышает 150 МБ');
    }
    final data = jsonDecode(utf8.decode(raw));
    if (data is! Map || data['format'] != 'ferrypane.sms.v1' ||
        data['messages'] is! List) {
      throw const FormatException('Неизвестный формат архива SMS');
    }
    final target = p.join(
      p.dirname(jsonFile.path),
      '${p.basenameWithoutExtension(jsonFile.path)}.html',
    );
    final output = await _availableName(target);
    await File(output).writeAsString(
      template(base64Encode(raw)),
      encoding: utf8,
      flush: true,
    );
    return output;
  }

  static Future<String> _availableName(String path) async {
    if (!await File(path).exists()) return path;
    for (var i = 1; i < 10000; i++) {
      final candidate =
          p.join(p.dirname(path), '${p.basenameWithoutExtension(path)} ($i).html');
      if (!await File(candidate).exists()) return candidate;
    }
    throw const FileSystemException('Не удалось выбрать имя SMS-архива');
  }

  static String template(String payload) =>
      _html.replaceAll('FERRYPANE_BASE64_DATA', payload);

  static const String _html = r'''<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="referrer" content="no-referrer">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src data:; base-uri 'none'; form-action 'none'">
<title>FerryPane — архив SMS</title>
<style>
:root {font:15px system-ui,-apple-system,"Segoe UI",sans-serif;color:#1b2538;background:#f2f5fa}
*{box-sizing:border-box} body{margin:0;height:100vh;height:100dvh}
#layout{height:100%;display:grid;grid-template-columns:minmax(220px,330px) minmax(0,1fr)}
aside{border-right:1px solid #d5dce9;background:#fff;display:flex;flex-direction:column;min-height:0}
header{padding:17px;border-bottom:1px solid #e4e8f0}
h1{font-size:20px;margin:0 0 6px}small,.sub{color:#657287;font-size:12px}
input{display:block;width:100%;border:1px solid #cdd5e3;border-radius:9px;padding:11px;margin-top:12px;font:inherit;background:#fff}
#conversations{min-height:0;overflow:auto}
.person{border:0;border-bottom:1px solid #f0f2f6;background:transparent;padding:13px 16px;width:100%;text-align:left;cursor:pointer;color:inherit}
.person strong{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.person small{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;margin-top:4px}
.person:hover,.person.active{background:#edf3ff}
main{display:flex;flex-direction:column;min-width:0;min-height:0}
#thread-title{padding:17px;font-size:18px;font-weight:600;background:#fff;border-bottom:1px solid #e0e4ec;overflow:hidden;text-overflow:ellipsis}
#messages{flex:1;overflow:auto;padding:20px;display:flex;flex-direction:column;align-items:flex-start;gap:10px}
.bubble{max-width:min(82%,760px);white-space:pre-wrap;overflow-wrap:anywhere;border-radius:15px;padding:11px 14px;background:#fff;box-shadow:0 1px 3px #dfe5ed}
.bubble.out{align-self:flex-end;background:#dceaff}
.when{font-size:11px;color:#60738d;margin-top:7px}
#more{align-self:center;margin:10px;background:#fff;border:1px solid #ccd6e3;padding:9px 15px;border-radius:8px;cursor:pointer}
.empty{margin:auto;color:#63758e;text-align:center}
@media(max-width:680px){#layout{grid-template-columns:145px 1fr}.person{padding:10px}#messages{padding:10px}.bubble{max-width:95%}header{padding:10px}}
</style>
</head>
<body>
<div id="layout">
<aside>
<header><h1>Архив SMS</h1><div class="sub" id="meta">Локальный файл</div>
<label for="search" class="sub">Поиск по имени, номеру, тексту</label>
<input id="search" type="search" placeholder="Поиск…" autocomplete="off"></header>
<div id="conversations"></div>
</aside>
<main>
<div id="thread-title">Выберите переписку</div>
<div id="messages"><p class="empty">Все данные доступны без интернета.</p></div>
</main>
</div>
<script>
"use strict";
(function(){
  // Base64 consists only of [A-Za-z0-9+/=]; never inject source text as code.
  const bytes = Uint8Array.from(atob("FERRYPANE_BASE64_DATA"), c => c.charCodeAt(0));
  const archive = JSON.parse(new TextDecoder("utf-8").decode(bytes));
  const list = document.getElementById("conversations");
  const search = document.getElementById("search");
  const thread = document.getElementById("messages");
  const title = document.getElementById("thread-title");
  const meta = document.getElementById("meta");
  const groups = new Map();
  const number = value => String(value || "").replace(/[^+0-9]/g,"");
  const when = ms => ms ? new Date(Number(ms)).toLocaleString() : "Дата неизвестна";
  const messages = Array.isArray(archive.messages) ? archive.messages : [];
  meta.textContent = messages.length + " сообщений · " + (archive.exportedAtUtc || "дата неизвестна");
  for (const message of messages) {
    if (!message || typeof message !== "object") continue;
    const contact = String(message.contactName || message.address || "Неизвестный номер");
    const key = number(message.address) || contact;
    if (!groups.has(key)) groups.set(key, {title: contact, number: String(message.address || ""), items: []});
    const g = groups.get(key);
    if (message.contactName) g.title = String(message.contactName);
    g.items.push(message);
  }
  const conversations = [...groups.values()].sort((a,b) =>
    (Number(b.items[b.items.length - 1]?.date || 0)) -
    (Number(a.items[a.items.length - 1]?.date || 0)));
  let selected = null, visible = [], rendered = 0;
  function el(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    if (text !== undefined) node.textContent = String(text);
    return node;
  }
  function appendMessages() {
    const previous = thread.querySelector("#more");
    if (previous) previous.remove();
    const end = Math.min(rendered + 150, visible.length);
    const fragment = document.createDocumentFragment();
    for (; rendered < end; rendered++) {
      const msg = visible[rendered];
      const bubble = el("div", "bubble" + (Number(msg.type) === 2 ? " out" : ""));
      bubble.appendChild(el("div", "", msg.body == null ? "" : msg.body));
      bubble.appendChild(el("div", "when", when(msg.date) +
        (Number(msg.type) === 2 ? " · Отправлено" : " · Получено")));
      fragment.appendChild(bubble);
    }
    thread.appendChild(fragment);
    if (rendered < visible.length) {
      const more = el("button", "", "Показать ещё (" + (visible.length-rendered) + ")");
      more.id = "more"; more.type = "button";
      more.addEventListener("click", appendMessages);
      thread.appendChild(more);
    }
  }
  function openConversation(g) {
    selected = g;
    title.textContent = g.title + (g.title !== g.number ? " · " + g.number : "");
    visible = [...g.items].sort((a,b) => Number(a.date || 0) - Number(b.date || 0));
    rendered = 0; thread.replaceChildren(); appendMessages();
    thread.scrollTop = 0;
    drawList();
  }
  function drawList() {
    const q = search.value.trim().toLocaleLowerCase();
    list.replaceChildren();
    const fragment = document.createDocumentFragment();
    let count = 0;
    for (const g of conversations) {
      if (q && !g.title.toLocaleLowerCase().includes(q) &&
          !g.number.toLocaleLowerCase().includes(q) &&
          !g.items.some(m => String(m.body || "").toLocaleLowerCase().includes(q))) continue;
      const button = el("button", "person" + (selected === g ? " active" : ""));
      button.type = "button";
      button.appendChild(el("strong", "", g.title));
      const last = g.items[g.items.length-1];
      button.appendChild(el("small", "", String(last?.body || "").slice(0,140)));
      button.addEventListener("click", () => openConversation(g));
      fragment.appendChild(button);
      count++;
      if (count >= 5000) break;
    }
    list.appendChild(fragment);
    if (count === 0) list.appendChild(el("p", "empty", "Ничего не найдено"));
  }
  search.addEventListener("input", drawList);
  drawList();
  if (conversations.length) openConversation(conversations[0]);
})();
</script>
</body>
</html>''';
}
