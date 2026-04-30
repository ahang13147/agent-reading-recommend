const state = {
  mode: "daily",
  books: [],
  recommendations: [],
  scheme: null,
  collector: null,
  targets: [],
  selectedId: null,
  history: []
};

const labels = {
  daily: "每日推荐",
  active: "近期活跃",
  retention: "长篇留存"
};

const componentLabels = {
  monthMomentum: "月票动能",
  recommendMomentum: "推荐增长",
  commentMomentum: "讨论活跃",
  ratingPulse: "评分脉冲",
  updateConsistency: "更新稳定",
  confidence: "数据可信",
  bayesianRating: "贝叶斯评分",
  retentionIndex: "留存指数",
  commentDepth: "评论密度",
  recommendDensity: "推荐密度",
  ratingStability: "评分稳定"
};

function el(id) {
  return document.getElementById(id);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: { "content-type": "application/json" },
    ...options
  });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(text || `HTTP ${response.status}`);
  }
  return response.json();
}

function todayString() {
  const now = new Date();
  const yyyy = now.getFullYear();
  const mm = String(now.getMonth() + 1).padStart(2, "0");
  const dd = String(now.getDate()).padStart(2, "0");
  return `${yyyy}-${mm}-${dd}`;
}

function showToast(message) {
  const toast = el("toast");
  toast.textContent = message;
  toast.classList.add("show");
  window.clearTimeout(showToast.timer);
  showToast.timer = window.setTimeout(() => toast.classList.remove("show"), 2600);
}

function formatNumber(value) {
  const number = Number(value || 0);
  if (number >= 100000000) return `${(number / 100000000).toFixed(2)}亿`;
  if (number >= 10000) return `${(number / 10000).toFixed(1)}万`;
  return Math.round(number).toLocaleString("zh-CN");
}

function formatWords(value) {
  const number = Number(value || 0);
  if (number >= 100000000) return `${(number / 100000000).toFixed(2)}亿字`;
  if (number >= 10000) return `${(number / 10000).toFixed(1)}万字`;
  return `${Math.round(number).toLocaleString("zh-CN")}字`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function bookOf(item) {
  return item.Book || item.book || {};
}

function latestOf(item) {
  return item.LatestSnapshot || item.latestSnapshot || {};
}

function scoreOf(item) {
  return Number(item.Score ?? item.score ?? 0);
}

function itemId(item) {
  return bookOf(item).id;
}

function normalizeStatus(status) {
  const text = String(status || "");
  return text.includes("完") ? "完本" : "连载";
}

function loadCategoryFilter() {
  const select = el("categoryFilter");
  const current = select.value;
  const categories = [...new Set(state.books.map(book => book.category).filter(Boolean))].sort((a, b) => a.localeCompare(b, "zh-CN"));
  select.innerHTML = `<option value="">全部</option>${categories.map(category => `<option value="${escapeHtml(category)}">${escapeHtml(category)}</option>`).join("")}`;
  select.value = categories.includes(current) ? current : "";
}

function filteredItems() {
  const category = el("categoryFilter").value;
  const status = el("statusFilter").value;
  const minWords = Number(el("minWords").value || 0);
  return state.recommendations.filter(item => {
    const book = bookOf(item);
    if (category && book.category !== category) return false;
    if (status && normalizeStatus(book.status) !== status) return false;
    if (Number(book.wordCount || 0) < minWords) return false;
    return true;
  });
}

function renderSummary(items) {
  el("bookCount").textContent = state.books.length;
  el("modeLabel").textContent = labels[state.mode];
  el("topScore").textContent = items.length ? scoreOf(items[0]).toFixed(1) : "0";
  el("generatedAt").textContent = new Date().toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit" });
}

function renderRanking() {
  const items = filteredItems();
  const ranking = el("ranking");
  renderSummary(items);

  if (!items.length) {
    ranking.innerHTML = `<div class="book-card"><div class="rank-number">--</div><div class="book-main"><h2 class="book-title">暂无匹配结果</h2><p class="book-meta">调整筛选条件后会重新计算当前榜单。</p></div></div>`;
    return;
  }

  if (!state.selectedId || !items.some(item => itemId(item) === state.selectedId)) {
    state.selectedId = itemId(items[0]);
    loadHistory(state.selectedId);
  }

  ranking.innerHTML = items.map((item, index) => renderBookCard(item, index)).join("");
  ranking.querySelectorAll(".book-card").forEach(card => {
    card.addEventListener("click", () => {
      state.selectedId = card.dataset.id;
      loadHistory(state.selectedId);
      renderRanking();
    });
  });
}

function renderBookCard(item, index) {
  const book = bookOf(item);
  const latest = latestOf(item);
  const active = book.id === state.selectedId ? " active" : "";
  const score = scoreOf(item);
  const reason = item.Reason || item.reason || "";
  const meta = [
    book.author,
    book.category,
    normalizeStatus(book.status),
    formatWords(book.wordCount)
  ].filter(Boolean).join(" · ");

  const subMetric = state.mode === "retention"
    ? `衰减 ${(Number(item.DecayIndex ?? item.decayIndex ?? 0) * 100).toFixed(0)}%`
    : `评分 ${Number(latest.rating || 0).toFixed(1)} · 月票 ${formatNumber(latest.monthTickets)}`;

  return `
    <article class="book-card${active}" data-id="${escapeHtml(book.id)}">
      <div class="rank-number">${index + 1}</div>
      <div class="book-main">
        <h2 class="book-title">${escapeHtml(book.title)}</h2>
        <p class="book-meta">${escapeHtml(meta)}</p>
        <p class="reason">${escapeHtml(reason)}</p>
        ${renderCompactMeters(item)}
      </div>
      <div class="score-block">
        <span class="score-value">${score.toFixed(1)}</span>
        <span class="score-label">${escapeHtml(subMetric)}</span>
      </div>
    </article>
  `;
}

function renderCompactMeters(item) {
  if (state.mode === "daily") {
    const trend = Number(item.TrendScore ?? item.trendScore ?? 0);
    const retention = Number(item.RetentionScore ?? item.retentionScore ?? 0);
    return `
      ${renderMeter("趋势", trend)}
      ${renderMeter("留存", retention)}
    `;
  }

  const components = item.Components || item.components || {};
  const keys = Object.keys(components).filter(key => key !== "confidence").slice(0, 2);
  return keys.map(key => renderMeter(componentLabels[key] || key, Number(components[key] || 0))).join("");
}

function renderMeter(label, value) {
  const width = Math.max(0, Math.min(100, value));
  return `
    <div class="metric-row">
      <span class="metric-label">${escapeHtml(label)}</span>
      <span class="meter"><span style="width:${width}%"></span></span>
      <span class="metric-value">${width.toFixed(0)}</span>
    </div>
  `;
}

async function loadHistory(bookId) {
  if (!bookId) return;
  try {
    const payload = await api(`/api/books/${encodeURIComponent(bookId)}/history`);
    state.history = payload.snapshots || [];
    renderDetail();
  } catch (error) {
    showToast(`历史快照读取失败：${error.message}`);
  }
}

function renderDetail() {
  const item = state.recommendations.find(candidate => itemId(candidate) === state.selectedId);
  if (!item) return;

  const book = bookOf(item);
  const latest = latestOf(item);
  el("detailTitle").textContent = book.title || "选择一本书";

  const sourceUrl = book.sourceUrl
    ? `<a href="${escapeHtml(book.sourceUrl)}" target="_blank" rel="noreferrer">起点书页</a>`
    : "";

  const components = item.Components || item.components || null;
  const componentRows = components
    ? Object.entries(components).map(([key, value]) => renderMeter(componentLabels[key] || key, Number(value || 0))).join("")
    : `${renderMeter("趋势评分", Number(item.TrendScore || 0))}${renderMeter("留存评分", Number(item.RetentionScore || 0))}${renderMeter("留存能力", (1 - Number(item.DecayIndex || 0)) * 100)}`;

  el("detailBody").innerHTML = `
    <p>${escapeHtml(book.summary || "暂无简介")}</p>
    <p class="book-meta">${escapeHtml(book.author || "")} · ${escapeHtml(book.category || "")} · ${escapeHtml(normalizeStatus(book.status))} · ${escapeHtml(formatWords(book.wordCount))} ${sourceUrl}</p>
    <div class="snapshot-grid">
      <div class="snapshot-cell"><span>综合得分</span><strong>${scoreOf(item).toFixed(1)}</strong></div>
      <div class="snapshot-cell"><span>衰减指数</span><strong>${((Number(item.DecayIndex ?? 0)) * 100).toFixed(0)}%</strong></div>
      <div class="snapshot-cell"><span>推荐票</span><strong>${formatNumber(latest.recommendTickets)}</strong></div>
      <div class="snapshot-cell"><span>章节评论</span><strong>${formatNumber(latest.chapterComments)}</strong></div>
    </div>
    ${renderSparkline(state.history)}
    ${componentRows}
  `;
}

function renderSparkline(history) {
  const points = (history || []).map(snapshot => ({
    label: snapshot.capturedAt,
    value: Number(snapshot.monthTickets || 0) + (Number(snapshot.recommendTickets || 0) / 8) + (Number(snapshot.chapterComments || 0) / 4)
  }));
  if (points.length < 2) {
    return `<div class="sparkline"></div>`;
  }

  const width = 360;
  const height = 110;
  const pad = 14;
  const min = Math.min(...points.map(point => point.value));
  const max = Math.max(...points.map(point => point.value));
  const span = Math.max(1, max - min);
  const path = points.map((point, index) => {
    const x = pad + (index * (width - pad * 2)) / Math.max(1, points.length - 1);
    const y = height - pad - ((point.value - min) * (height - pad * 2)) / span;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  }).join(" ");

  return `
    <svg class="sparkline" viewBox="0 0 ${width} ${height}" role="img" aria-label="互动趋势曲线">
      <polyline points="${path}" fill="none" stroke="#0f766e" stroke-width="4" stroke-linecap="round" stroke-linejoin="round"></polyline>
      <line x1="${pad}" y1="${height - pad}" x2="${width - pad}" y2="${height - pad}" stroke="#dbe2dc"></line>
    </svg>
  `;
}

function renderScheme() {
  if (!state.scheme) return;
  const metricItems = (state.scheme.metricAssumptions || []).map(item => `<li>${escapeHtml(item)}</li>`).join("");
  const collectionItems = (state.scheme.collectionPlan || []).map(item => `<li>${escapeHtml(item)}</li>`).join("");
  const active = state.scheme.activeFormula || {};
  const retention = state.scheme.retentionFormula || {};

  el("schemeGrid").innerHTML = `
    <article class="scheme-block">
      <h3>指标口径</h3>
      <ul>${metricItems}</ul>
    </article>
    <article class="scheme-block">
      <h3>近期活跃</h3>
      <p>月票 ${escapeHtml(active.monthMomentum)}，推荐增长 ${escapeHtml(active.recommendMomentum)}，讨论活跃 ${escapeHtml(active.commentMomentum)}，评分 ${escapeHtml(active.ratingPulse)}，更新 ${escapeHtml(active.updateConsistency)}。</p>
      <p>${escapeHtml(active.note || "")}</p>
    </article>
    <article class="scheme-block">
      <h3>长篇留存</h3>
      <p>贝叶斯评分 ${escapeHtml(retention.bayesianRating)}，留存 ${escapeHtml(retention.retentionIndex)}，评论密度 ${escapeHtml(retention.commentDepth)}，推荐密度 ${escapeHtml(retention.recommendDensity)}，评分稳定 ${escapeHtml(retention.ratingStability)}。</p>
      <p>${escapeHtml(retention.note || "")}</p>
    </article>
    <article class="scheme-block">
      <h3>采集闭环</h3>
      <ul>${collectionItems}</ul>
    </article>
  `;
}

function renderCollector() {
  if (!state.collector) return;
  const badge = el("collectorBadge");
  const text = state.collector.cookieConfigured
    ? "Cookie 源就绪"
    : state.collector.inboxWaiting
      ? "有待导入快照"
      : "演示快照源";
  badge.textContent = text;
  badge.title = state.collector.note || "";
}

function renderTargets() {
  const list = el("targetList");
  if (!list) return;
  if (!state.targets.length) {
    list.innerHTML = `<div class="target-item"><span class="target-meta">暂无追踪目标。</span></div>`;
    return;
  }

  list.innerHTML = state.targets.map(target => `
    <div class="target-item">
      <a href="${escapeHtml(target.url)}" target="_blank" rel="noreferrer">${escapeHtml(target.name || target.id)}</a>
      <span class="target-meta">${escapeHtml(target.cadence || "manual")} · 上限 ${Number(target.limit || 0)} · ${target.enabled ? "启用" : "暂停"}</span>
    </div>
  `).join("");
}

async function loadRecommendations() {
  const payload = await api(`/api/recommendations?mode=${encodeURIComponent(state.mode)}`);
  state.recommendations = payload.items || [];
  renderRanking();
  renderDetail();
}

async function init() {
  try {
    const [books, scheme, collector, targets] = await Promise.all([
      api("/api/books"),
      api("/api/scheme"),
      api("/api/collector/status"),
      api("/api/targets")
    ]);
    state.books = books.items || [];
    state.scheme = scheme;
    state.collector = collector;
    state.targets = targets.items || [];
    el("captureDate").value = todayString();
    loadCategoryFilter();
    renderScheme();
    renderCollector();
    renderTargets();
    await loadRecommendations();
  } catch (error) {
    showToast(`应用初始化失败：${error.message}`);
  }
}

document.querySelectorAll(".tab").forEach(button => {
  button.addEventListener("click", async () => {
    document.querySelectorAll(".tab").forEach(tab => tab.classList.remove("active"));
    button.classList.add("active");
    state.mode = button.dataset.mode;
    await loadRecommendations();
  });
});

["categoryFilter", "statusFilter", "minWords"].forEach(id => {
  el(id).addEventListener("input", renderRanking);
});

el("refreshButton").addEventListener("click", async () => {
  try {
    el("refreshButton").disabled = true;
    const result = await api("/api/track/refresh", { method: "POST", body: "{}" });
    showToast(`快照已刷新：${result.imported} 条，来源 ${result.source}`);
    await loadRecommendations();
  } catch (error) {
    showToast(`刷新失败：${error.message}`);
  } finally {
    el("refreshButton").disabled = false;
  }
});

el("importCaptureButton").addEventListener("click", async () => {
  const html = el("captureText").value.trim();
  const sourceUrl = el("captureUrl").value.trim();
  const capturedAt = el("captureDate").value || todayString();
  const resultLabel = el("importResult");

  if (!html) {
    showToast("先粘贴起点页面 HTML 或可见文本。");
    return;
  }

  try {
    el("importCaptureButton").disabled = true;
    const result = await api("/api/import/qidian-html", {
      method: "POST",
      body: JSON.stringify({ html, sourceUrl, capturedAt })
    });
    resultLabel.textContent = `发现 ${result.discovered} 本，导入书籍 ${result.importedBooks} 本，导入快照 ${result.importedSnapshots} 条。`;
    if (result.warnings && result.warnings.length) {
      showToast(`有 ${result.warnings.length} 条记录缺少可解析指标，已先加入书籍队列。`);
    } else {
      showToast("真实页面数据已导入。");
    }
    const books = await api("/api/books");
    state.books = books.items || [];
    loadCategoryFilter();
    await loadRecommendations();
  } catch (error) {
    resultLabel.textContent = "导入失败";
    showToast(`导入失败：${error.message}`);
  } finally {
    el("importCaptureButton").disabled = false;
  }
});

init();
