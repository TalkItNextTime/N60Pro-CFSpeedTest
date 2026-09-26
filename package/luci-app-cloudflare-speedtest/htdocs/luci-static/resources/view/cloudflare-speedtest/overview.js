'use strict';
'require view';
'require form';
'require rpc';
'require uci';
'require poll';
'require ui';
'require dom';

var POLL_ACTIVE_MS = 3000;
var POLL_IDLE_MS = 15000;

var callStatus = rpc.declare({
	object: 'cloudflare-speedtest',
	method: 'status',
	expect: { '': {} }
});

var callResult = rpc.declare({
	object: 'cloudflare-speedtest',
	method: 'result',
	expect: { '': {} }
});

var callStart = rpc.declare({
	object: 'cloudflare-speedtest',
	method: 'start',
	params: [ 'mode' ],
	expect: { '': {} }
});

var callStop = rpc.declare({
	object: 'cloudflare-speedtest',
	method: 'stop',
	expect: { '': {} }
});

var callValidate = rpc.declare({
	object: 'cloudflare-speedtest',
	method: 'validate',
	expect: { '': {} }
});

var callLogs = rpc.declare({
	object: 'cloudflare-speedtest',
	method: 'logs',
	params: [ 'bytes' ],
	expect: { '': {} }
});

var callClearLogs = rpc.declare({
	object: 'cloudflare-speedtest',
	method: 'clear_logs',
	expect: { '': {} }
});

var callConfigSummary = rpc.declare({
	object: 'cloudflare-speedtest',
	method: 'config_summary',
	expect: { '': {} }
});

var callSetToken = rpc.declare({
	object: 'cloudflare-speedtest',
	method: 'set_token',
	params: [ 'token', 'clear' ],
	expect: { '': {} }
});

var ERROR_HINTS = {
	CONFIG_TOKEN_MISSING: '未配置 Cloudflare API Token',
	CONFIG_ZONE_MISSING: '未配置 Cloudflare Zone',
	CONFIG_ZONE_INVALID: 'Cloudflare Zone 格式无效',
	CONFIG_INTERVAL_INVALID: '测速周期配置无效',
	GEO_ALL_PROVIDERS_FAILED: '归属查询失败，无法安全确定地区',
	CFST_TIMEOUT: '测速任务超时',
	RESULT_NO_QUALIFIED_IP: '没有符合条件的优选 IP',
	RESULT_BAD_CSV: '测速结果文件无效',
	CF_API_UNAUTHORIZED: 'Cloudflare API 未授权',
	CF_API_FORBIDDEN: 'Cloudflare API 权限不足',
	CF_API_RATE_LIMITED: 'Cloudflare API 限流',
	CF_API_TEMPORARY: 'Cloudflare API 暂时不可用',
	DNS_MULTIPLE_RECORDS: 'DNS 记录冲突，存在多条同名记录',
	DNS_VERIFY_FAILED: 'DNS 写入后校验失败',
	DNS_CLEANUP_FAILED: '新记录已更新，旧记录清理失败',
	TASK_ALREADY_RUNNING: '已有任务在运行',
	TASK_LOCK_WRITE_FAILED: '无法获取任务锁',
	NAMING_UNRESOLVED: '无法解析安全的地区运营商域名',
	CONFIG_INVALID: '配置无效'
};

var ACTIVE_PHASES = {
	preparing: true,
	detecting_network: true,
	testing: true,
	testing_recheck: true,
	testing_latency: true,
	testing_download: true,
	validating_result: true,
	updating_dns: true,
	cleaning_old_record: true
};

function isActivePhase(phase) {
	return !!(phase && ACTIVE_PHASES[phase]);
}

function phaseMeta(phase) {
	var map = {
		idle: [ _('空闲'), 'neutral' ],
		preparing: [ _('准备任务'), 'active' ],
		detecting_network: [ _('检测网络'), 'active' ],
		testing: [ _('正在测速'), 'active' ],
		testing_recheck: [ _('复测节点'), 'active' ],
		testing_latency: [ _('延迟测试'), 'active' ],
		testing_download: [ _('下载测速'), 'active' ],
		validating_result: [ _('验证结果'), 'active' ],
		updating_dns: [ _('更新 DNS'), 'active' ],
		cleaning_old_record: [ _('清理记录'), 'active' ],
		success: [ _('任务完成'), 'success' ],
		partial_success: [ _('部分完成'), 'warning' ],
		cancelled: [ _('已停止'), 'warning' ],
		failed: [ _('任务失败'), 'danger' ]
	};
	return map[phase] || [ fmtValue(phase, _('空闲')), 'neutral' ];
}

function progressPercent(message) {
	var match = String(message || '').match(/[（(](\d{1,3})%/);
	if (!match)
		return 0;
	return Math.max(0, Math.min(100, Number(match[1]) || 0));
}

function renderHeader(status) {
	var meta = phaseMeta((status || {}).phase || 'idle');
	return E('div', { 'class': 'cfst-topbar' }, [
		E('div', { 'class': 'cfst-brand' }, [
			E('h2', {}, _('Cloudflare 优选 IP')),
			E('p', {}, _('测速、候选筛选与 DNS 发布控制台'))
		]),
		E('div', {
			'class': 'cfst-runtime cfst-tone-' + meta[1],
			'id': 'cfst-runtime'
		}, [
			E('span', { 'class': 'cfst-runtime-dot' }),
			E('div', {}, [
				E('span', { 'class': 'cfst-runtime-label' }, _('任务状态')),
				E('strong', { 'class': 'cfst-runtime-value', 'id': 'cfst-header-phase' }, meta[0])
			])
		])
	]);
}

function addDismissibleNotification(title, content, level) {
	var msg = ui.addNotification(title, content, level);
	if (msg) {
		var close = msg.querySelector('button');
		if (close) {
			close.addEventListener('click', function() {
				window.setTimeout(function() {
					if (msg.parentNode)
						msg.parentNode.removeChild(msg);
				}, 0);
			});
		}
	}
	return msg;
}

function notifyError(res) {
	var code = (res && (res.error_code || res.code)) || '';
	var backend = (res && (res.error_message || res.message)) || '';
	var hint = ERROR_HINTS[code] || _('操作失败');
	var text = hint;
	if (code)
		text += ' [' + code + ']';
	if (backend)
		text += ' — ' + backend;
	addDismissibleNotification(null, E('p', {}, text), 'danger');
}

function notifyOk(message) {
	addDismissibleNotification(null, E('p', {}, message), 'info');
}

function fmtValue(v, fallback) {
	if (v === null || v === undefined || v === '')
		return fallback || '—';
	return String(v);
}

function fmtDateTime(v) {
	if (v === null || v === undefined || v === '') return _('\u672a\u5b89\u6392');
	var n = Number(v);
	if (!isFinite(n) || n <= 0) return String(v);
	try { return new Date(n * 1000).toLocaleString(); } catch (e) { return String(v); }
}

function formatNextRun(status, summary) {
	status = status || {};
	summary = summary || {};
	if (status.schedule_enabled === false || summary.schedule_enabled === false)
		return _('\u5df2\u7981\u7528');
	return fmtDateTime(status.next_run_at || status.next_run || summary.next_run_at);
}

/* Node ownership comes from the colo the download actually landed in. The
 * ipinfo region of an anycast address is a registration address and does not
 * describe the datacenter, so it must not be used here. colo_name is written
 * into state and candidates at test time; files from older versions lack it. */
function formatColo(obj, fallback) {
	if (!obj || typeof obj !== 'object')
		return fallback || _('未知');
	var code = String(obj.colo || '').trim();
	if (code === '' || code === 'N/A')
		return fallback || _('未知');
	var name = String(obj.colo_name || '').trim();
	return name ? code + ' / ' + name : code;
}

function fmtNodeTime(v) {
	if (v === null || v === undefined || v === '')
		return '—';
	return fmtDateTime(v);
}

function formatLocalGeo(obj) {
	if (!obj || typeof obj !== 'object')
		return _('\u672a\u67e5\u8be2');

	/* This card describes the local public network, never the selected
	 * Cloudflare node. UAPIS myip supplies the Chinese region and llc fields;
	 * the maps keep old cached city/ISP codes readable after an upgrade. */
	var cityNames = {
		bj: '\u5317\u4eac', sh: '\u4e0a\u6d77', tj: '\u5929\u6d25', cq: '\u91cd\u5e86',
		sz: '\u6df1\u5733', dg: '\u4e1c\u839e', gz: '\u5e7f\u5dde', hz: '\u676d\u5dde',
		nj: '\u5357\u4eac', su: '\u82cf\u5dde', wh: '\u6b66\u6c49', cd: '\u6210\u90fd',
		xa: '\u897f\u5b89', cs: '\u957f\u6c99', fz: '\u798f\u5dde', xm: '\u53a6\u95e8'
	};
	var ispNames = {
		ct: '\u7535\u4fe1', cu: '\u8054\u901a', cm: '\u79fb\u52a8', cmcc: '\u79fb\u52a8',
		cernet: '\u6559\u80b2\u7f51', cbn: '\u5e7f\u7535'
	};
	var region = String(obj.region || '').trim();
	var city = String(obj.city || '').trim();
	var isp = String(obj.llc || '').trim() || String(obj.isp || '').trim();
	if (region) {
		var regionParts = region.split(/\s+/);
		city = regionParts[regionParts.length - 1] || city;
	}
	city = cityNames[city.toLowerCase()] || city.replace(/\u5e02$/, '');
	isp = ispNames[isp.toLowerCase()] || isp;
	if (city && isp)
		return city + isp;
	return city || isp || _('\u672a\u67e5\u8be2');
}

function fmtObjectField(obj, key) {
	if (!obj || typeof obj !== 'object')
		return '—';
	return fmtValue(obj[key]);
}

function renderStatusCards(status, result, summary) {
	status = status || {};
	result = result || {};
	summary = summary || {};

	var phase = status.phase || 'idle';
	var message = status.message || '';
	var nextRun = formatNextRun(status, summary);
	var tested = result.last_tested || {};
	var published = result.last_published || {};
	var managed = result.managed_record || {};
	var localNetwork = result.network_cache || {};
	var preferred = result.last_published || result.last_tested || {};
	var meta = phaseMeta(phase);
	var pct = progressPercent(message);

	var runPanel = E('section', { 'class': 'cfst-run-panel' }, [
		E('p', { 'class': 'cfst-panel-kicker' }, _('当前任务')),
		E('h3', { 'id': 'cfst-phase' }, meta[0]),
		E('p', { 'class': 'cfst-run-message', 'id': 'cfst-message' }, fmtValue(message, _('等待任务'))),
		E('div', { 'class': 'cfst-progress-track', 'aria-hidden': 'true' }, [
			E('div', {
				'class': 'cfst-progress-value',
				'id': 'cfst-progress-value',
				'style': 'width:' + pct + '%'
			})
		]),
		E('div', { 'class': 'cfst-run-footer' }, [
			E('div', {}, [
				E('span', {}, _('下次自动任务')),
				E('strong', { 'id': 'cfst-next-run' }, nextRun)
			]),
			E('div', {}, [
				E('span', {}, _('当前进度')),
				E('strong', { 'id': 'cfst-progress-label' }, pct ? pct + '%' : (isActivePhase(phase) ? _('进行中') : '—'))
			])
		]),
		/* Live candidates belong to the running task, so they share its card. */
		E('div', { 'class': 'cfst-run-candidates', 'id': 'cfst-candidates' }, [ renderCandidatePanel(status) ])
	]);

	var cardTested = E('section', { 'class': 'status-card cfst-status-card' }, [
		E('h3', {}, _('最近测速')),
		E('div', { 'class': 'cfst-data-row' }, [
			E('span', { 'class': 'cfst-data-label' }, _('候选 IP')),
			E('span', { 'class': 'cfst-data-value', 'id': 'cfst-last-tested-ip' }, fmtObjectField(tested, 'ip'))
		]),
		E('div', { 'class': 'cfst-data-row' }, [
			E('span', { 'class': 'cfst-data-label' }, _('节点归属')),
			E('span', { 'class': 'cfst-data-value', 'id': 'cfst-last-tested-geo' }, formatColo(tested, '—'))
		]),
		E('div', { 'class': 'cfst-data-row' }, [
			E('span', { 'class': 'cfst-data-label' }, _('延迟 / 速度')),
			E('span', { 'class': 'cfst-data-value', 'id': 'cfst-last-tested-metrics' },
				fmtObjectField(tested, 'latency_ms') + ' ms / ' + fmtObjectField(tested, 'speed_mbps') + ' Mbps')
		]),
		E('div', { 'class': 'cfst-data-row' }, [
			E('span', { 'class': 'cfst-data-label' }, _('最近测速时间')),
			E('span', { 'class': 'cfst-data-value', 'id': 'cfst-last-tested-at' }, fmtNodeTime(tested.tested_at))
		])
	]);

	var cardPublished = E('section', { 'class': 'status-card cfst-status-card' }, [
		E('h3', {}, _('DNS 发布')),
		E('div', { 'class': 'cfst-data-row' }, [
			E('span', { 'class': 'cfst-data-label' }, _('发布 IP')),
			E('span', { 'class': 'cfst-data-value', 'id': 'cfst-last-published-ip' }, fmtObjectField(published, 'ip'))
		]),
		E('div', { 'class': 'cfst-data-row' }, [
			E('span', { 'class': 'cfst-data-label' }, _('管理记录')),
			E('span', { 'class': 'cfst-data-value', 'id': 'cfst-managed' },
				fmtObjectField(managed, 'name') || fmtObjectField(published, 'hostname') || '—')
		]),
		E('div', { 'class': 'cfst-data-row' }, [
			E('span', { 'class': 'cfst-data-label' }, _('最近发布时间')),
			E('span', { 'class': 'cfst-data-value', 'id': 'cfst-last-published-at' }, fmtNodeTime(published.published_at))
		])
	]);

	var cardNetwork = E('section', { 'class': 'status-card cfst-status-card' }, [
		E('h3', {}, _('网络信息')),
		E('div', { 'class': 'cfst-data-row' }, [
			E('span', { 'class': 'cfst-data-label' }, _('本地归属')),
			E('span', { 'class': 'cfst-data-value', 'id': 'cfst-geo' }, formatLocalGeo(localNetwork))
		]),
		E('div', { 'class': 'cfst-data-row' }, [
			E('span', { 'class': 'cfst-data-label' }, _('优选节点')),
			E('span', { 'class': 'cfst-data-value', 'id': 'cfst-preferred-geo' }, formatColo(preferred))
		]),
		E('div', { 'class': 'cfst-data-row' }, [
			E('span', { 'class': 'cfst-data-label' }, _('API Token')),
			E('span', { 'class': 'cfst-data-value', 'id': 'cfst-token-state' },
				summary.token_configured ? _('已配置') : _('未配置'))
		])
	]);

	return E('div', { 'class': 'cfst-dashboard' }, [
		runPanel,
		E('div', { 'class': 'cfst-status-stack' }, [ cardTested, cardPublished, cardNetwork ])
	]);
}

function setButtonState(btnStartUpdate, btnStartOnly, btnStop, phase, startPending) {
	var active = isActivePhase(phase) || !!startPending;
	btnStartUpdate.disabled = active;
	btnStartOnly.disabled = active;
	btnStop.disabled = !active;
	if (active) {
		btnStartUpdate.setAttribute('disabled', 'disabled');
		btnStartOnly.setAttribute('disabled', 'disabled');
		btnStop.removeAttribute('disabled');
	}
	else {
		btnStartUpdate.removeAttribute('disabled');
		btnStartOnly.removeAttribute('disabled');
		btnStop.setAttribute('disabled', 'disabled');
	}
}

function updateCardDom(status, result, summary) {
	status = status || {};
	result = result || {};
	summary = summary || {};
	var tested = result.last_tested || {};
	var published = result.last_published || {};
	var managed = result.managed_record || {};
	/* This card is for the local public network, not the selected node. */
	var localNetwork = result.network_cache || {};
	var preferred = result.last_published || result.last_tested || {};
	var phase = status.phase || 'idle';
	var meta = phaseMeta(phase);
	var pct = progressPercent(status.message);

	var setText = function(id, text) {
		var el = document.getElementById(id);
		if (el)
			el.textContent = text;
	};

	setText('cfst-phase', meta[0]);
	setText('cfst-header-phase', meta[0]);
	setText('cfst-message', fmtValue(status.message, _('空闲')));
	setText('cfst-next-run', formatNextRun(status, summary));
	setText('cfst-progress-label', pct ? pct + '%' : (isActivePhase(phase) ? _('进行中') : '—'));
	setText('cfst-last-tested-ip', fmtObjectField(tested, 'ip'));
	setText('cfst-last-tested-geo', formatColo(tested, '—'));
	setText('cfst-last-tested-at', fmtNodeTime(tested.tested_at));
	setText('cfst-last-tested-metrics',
		fmtObjectField(tested, 'latency_ms') + ' ms / ' + fmtObjectField(tested, 'speed_mbps') + ' Mbps');
	setText('cfst-last-published-ip', fmtObjectField(published, 'ip'));
	setText('cfst-last-published-at', fmtNodeTime(published.published_at));
	var preferredNode = published.colo ? published : tested;
	setText('cfst-preferred-geo', formatColo(preferredNode));
	setText('cfst-geo', formatLocalGeo(localNetwork));
	setText('cfst-managed', fmtObjectField(managed, 'name') || fmtObjectField(published, 'hostname') || '—');
	setText('cfst-token-state', summary.token_configured ? _('已配置') : _('未配置'));

	var runtime = document.getElementById('cfst-runtime');
	if (runtime)
		runtime.className = 'cfst-runtime cfst-tone-' + meta[1];
	var progress = document.getElementById('cfst-progress-value');
	if (progress)
		progress.style.width = pct + '%';
}

function renderCandidatePanel(status) {
    var rows = (status && Array.isArray(status.candidates)) ? status.candidates : [];
    var body = rows.length ? rows.map(function(row) {
        var speed = Number(row.speed_mbps);
        var latency = Number(row.latency_ms);
        var loss = Number(row.loss_ratio) * 100;
        /* Live rows carry downloading/downloaded; final CSV rows omit them and
         * fall back to the latency_pass/qualified verdict. */
        var state, stateClass;
        if (row.downloading) {
            state = _('下载中'); stateClass = 'is-testing';
        } else if (row.qualified) {
            state = _('下载通过'); stateClass = 'is-passed';
        } else if (row.downloaded) {
            state = _('速度不足'); stateClass = 'is-rejected';
        } else if (row.latency_pass) {
            state = _('等待下载'); stateClass = 'is-pending';
        } else {
            state = _('延迟未通过'); stateClass = 'is-rejected';
        }
        return E('tr', {}, [
            E('td', {}, fmtValue(row.ip)),
            E('td', {}, isFinite(latency) ? latency.toFixed(1) + ' ms' : '—'),
            E('td', {}, (row.downloaded || row.qualified) && isFinite(speed) ? speed.toFixed(2) + ' Mbps' : (row.downloading ? _('测速中…') : '—')),
            E('td', {}, isFinite(loss) ? loss.toFixed(1) + '%' : '—'),
            E('td', {}, formatColo(row, '—')),
            E('td', {}, E('span', { 'class': 'cfst-result-state ' + stateClass }, state))
        ]);
    }) : [ E('tr', {}, [ E('td', { 'colspan': '6', 'class': 'cfst-empty-row' }, _('等待测速结果…')) ]) ];
    return E('section', { 'class': 'cfst-candidates' }, [
        E('div', { 'class': 'cfst-section-head' }, [
			E('div', {}, [
				E('h3', {}, _('实时测速候选 IP')),
				E('p', {}, _('当前任务产生的延迟、速度与门槛判定结果'))
			]),
			E('span', { 'class': 'cfst-count' }, rows.length + ' ' + _('条结果'))
		]),
        E('div', { 'class': 'cfst-table-wrap' }, [
            /* dom.append() does not flatten nested arrays; a nested row array
             * would be stringified to "[object HTMLTableRowElement],...". */
            E('table', { 'class': 'table' }, [
                E('tr', {}, [ E('th', {}, _('IP')), E('th', {}, _('延迟')), E('th', {}, _('速度')),
                    E('th', {}, _('丢包')), E('th', {}, _('节点归属')), E('th', {}, _('状态')) ])
            ].concat(body))
        ])
    ]);
}

function updateCandidateDom(status) {
    var host = document.getElementById('cfst-candidates');
    if (!host)
        return;
    dom.content(host, renderCandidatePanel(status || {}));
}

function renderActions(view) {
	var btnStartUpdate = E('button', {
		'class': 'btn cbi-button cbi-button-action important',
		'type': 'button'
	}, _('立即测速并更新 DNS'));

	var btnStartOnly = E('button', {
		'class': 'btn cbi-button cbi-button-action',
		'type': 'button'
	}, _('仅测速'));

	var btnStop = E('button', {
		'class': 'btn cbi-button cbi-button-negative',
		'type': 'button',
		'disabled': 'disabled'
	}, _('停止当前任务'));

	var btnValidate = E('button', {
		'class': 'btn cbi-button cbi-button-apply',
		'type': 'button'
	}, _('验证凭据'));

	btnStartUpdate.addEventListener('click', function() {
		view._startPending = true;
		view._startObserved = false;
		setButtonState(btnStartUpdate, btnStartOnly, btnStop, (view._lastStatus || {}).phase, true);
		return callStart('test-and-update').then(function(res) {
			if (res && res.error_code) {
				view._startPending = false;
				setButtonState(btnStartUpdate, btnStartOnly, btnStop, (view._lastStatus || {}).phase, false);
				notifyError(res);
				return;
			}
			if (res && res.accepted === false) {
				view._startPending = false;
				setButtonState(btnStartUpdate, btnStartOnly, btnStop, (view._lastStatus || {}).phase, false);
				notifyError(res);
				return;
			}
			notifyOk(_('已接受：测速并更新 DNS（test-and-update）'));
			return view.refreshAll();
		}).catch(function(err) {
			view._startPending = false;
			setButtonState(btnStartUpdate, btnStartOnly, btnStop, (view._lastStatus || {}).phase, false);
			notifyError({ error_message: String(err) });
		});
	});

	btnStartOnly.addEventListener('click', function() {
		view._startPending = true;
		view._startObserved = false;
		setButtonState(btnStartUpdate, btnStartOnly, btnStop, (view._lastStatus || {}).phase, true);
		return callStart('test-only').then(function(res) {
			if (res && res.error_code) {
				view._startPending = false;
				setButtonState(btnStartUpdate, btnStartOnly, btnStop, (view._lastStatus || {}).phase, false);
				notifyError(res);
				return;
			}
			if (res && res.accepted === false) {
				view._startPending = false;
				setButtonState(btnStartUpdate, btnStartOnly, btnStop, (view._lastStatus || {}).phase, false);
				notifyError(res);
				return;
			}
			notifyOk(_('已接受：仅测速（test-only）'));
			return view.refreshAll();
		}).catch(function(err) {
			view._startPending = false;
			setButtonState(btnStartUpdate, btnStartOnly, btnStop, (view._lastStatus || {}).phase, false);
			notifyError({ error_message: String(err) });
		});
	});

	btnStop.addEventListener('click', function() {
		btnStop.disabled = true;
		return callStop().then(function(res) {
			if (res && res.error_code) {
				setButtonState(btnStartUpdate, btnStartOnly, btnStop,
					(view._lastStatus || {}).phase, view._startPending);
				notifyError(res);
				return;
			}
			view._startPending = false;
			view._startObserved = false;
			setButtonState(btnStartUpdate, btnStartOnly, btnStop,
				(view._lastStatus || {}).phase, false);
			notifyOk(_('已请求停止当前任务（stop）'));
			return view.refreshAll();
		}).catch(function(err) {
			notifyError({ error_message: String(err) });
		});
	});

	btnValidate.addEventListener('click', function() {
		return callValidate().then(function(res) {
			if (res && res.valid) {
				notifyOk(_('凭据验证通过'));
				return;
			}
			notifyError(res || { error_code: 'CONFIG_INVALID' });
		}).catch(function(err) {
			notifyError({ error_message: String(err) });
		});
	});

	view._btnStartUpdate = btnStartUpdate;
	view._btnStartOnly = btnStartOnly;
	view._btnStop = btnStop;

	return E('section', { 'class': 'cfst-actions' }, [
		E('div', { 'class': 'cfst-actions-copy' }, [
			E('h3', {}, _('任务控制')),
			E('p', {}, _('手动任务与定时任务共用同一运行锁'))
		]),
		E('div', { 'class': 'cfst-action-buttons' }, [
			btnStartUpdate, btnStartOnly, btnStop, btnValidate
		])
	]);
}

function renderLogsPanel(view) {
	var pre = E('pre', {
		'id': 'cfst-logs',
		'class': 'cfst-log-output'
	}, '');

	var autoRefresh = E('input', { 'type': 'checkbox', 'id': 'cfst-logs-auto' });
	autoRefresh.checked = true;

	var btnRefresh = E('button', { 'class': 'btn cbi-button', 'type': 'button' }, _('刷新日志'));
	var btnClear = E('button', { 'class': 'btn cbi-button cbi-button-remove', 'type': 'button' }, _('清空日志'));

	function loadLogs() {
		return callLogs(65536).then(function(res) {
			var text = '';
			if (typeof res === 'string')
				text = res;
			else if (res && typeof res.log === 'string')
				text = res.log;
			else if (res && typeof res.logs === 'string')
				text = res.logs;
			else if (res && typeof res.data === 'string')
				text = res.data;
			else if (res)
				text = JSON.stringify(res, null, 2);
			pre.textContent = text || _('（无日志）');
		}).catch(function(err) {
			pre.textContent = String(err);
		});
	}

	btnRefresh.addEventListener('click', function() {
		return loadLogs();
	});

	btnClear.addEventListener('click', function() {
		return callClearLogs().then(function(res) {
			if (res && res.error_code) {
				notifyError(res);
				return;
			}
			notifyOk(_('日志已清空（clear_logs）'));
			return loadLogs();
		}).catch(function(err) {
			notifyError({ error_message: String(err) });
		});
	});

	view._loadLogs = loadLogs;
	view._logsAuto = autoRefresh;

	return E('div', {}, [
		E('div', { 'class': 'cfst-log-tools' }, [
			btnRefresh, btnClear,
			E('label', {}, [ autoRefresh, ' ', _('自动刷新') ])
		]),
		pre
	]);
}

/*
 * The preferred-provider fields are displayed in the `main` form section but
 * belong to the named `preferred` UCI section. `ucisection` is supported by
 * recent LuCI releases, but explicit load/write handlers keep this alias
 * working on older 24.x builds as well and make the persistence target
 * unambiguous.
 */
function bindPreferredOption(option) {
	option.ucisection = 'preferred';
	option.load = function() {
		return uci.get('cloudflare-speedtest', 'preferred', this.ucioption || this.option);
	};
	option.write = function(section_id, value) {
		return uci.set('cloudflare-speedtest', 'preferred',
			this.ucioption || this.option, value);
	};
	return option;
}

function buildConfigMap(view, summary) {
	var m = new form.Map('cloudflare-speedtest', _('设置'));

	m.chain('cloudflare-speedtest');

	var s = m.section(form.NamedSection, 'main', 'main', _('插件配置'));
	s.addremove = false;
	s.anonymous = false;

	s.tab('basic', _('基本设置'));
	s.tab('cloudflare', _('Cloudflare'));
	s.tab('performance', _('测速策略'));
	s.tab('sources', _('IP 来源'));
	s.tab('naming', _('地区命名'));
	s.tab('logs', _('运行日志'));

	var o;
	var tokenOption = null;
	var clearOption = null;

	o = s.taboption('basic', form.Flag, 'enabled', _('启用定时任务'));
	o.rmempty = false;
	o.default = '1';

	o = s.taboption('basic', form.Value, 'interval_hours', _('测速周期（小时）'));
	o.datatype = 'and(uinteger,min(1),max(24))';
	o.rmempty = false;
	o.default = '6';

	o = s.taboption('basic', form.Value, 'startup_delay', _('启动延迟（秒）'));
	o.datatype = 'and(uinteger,min(0),max(3600))';
	o.rmempty = false;
	o.default = '120';

	o = s.taboption('basic', form.ListValue, 'log_level', _('日志级别'));
	o.value('debug', 'debug');
	o.value('info', 'info');
	o.value('warn', 'warn');
	o.value('error', 'error');
	o.default = 'info';

	tokenOption = s.taboption('cloudflare', form.Value, '_api_token', _('API Token'));
	o = tokenOption;
	o.password = true;
	tokenOption.optional = true;
	tokenOption.rmempty = true;
	tokenOption.placeholder = _('已配置；留空保持不变');
	tokenOption.ucisection = 'cloudflare';
	tokenOption.cfgvalue = function() {
		/* Never load the secret through ordinary UCI; an empty input means unchanged. */
		return '';
	};
	tokenOption.write = function(section_id, value) {
		/* Save the secret through the dedicated RPC during LuCI's normal form parse. */
		if (clearOption && clearOption.formvalue(section_id) === '1')
			return callSetToken('', true).then(function(res) {
				if (res && res.error_code)
					return Promise.reject(new Error(res.error_message || res.error_code));
				notifyOk(_('Token \u5df2\u6e05\u9664'));
			});

		return callSetToken(value, false).then(function(res) {
			if (res && res.error_code)
				return Promise.reject(new Error(res.error_message || res.error_code));
			notifyOk(_('Token \u5df2\u901a\u8fc7 set_token \u66f4\u65b0'));
		});
	};
	tokenOption.remove = function() {
		/* Do not remove the real UCI option when the masked input is empty. */
		return true;
	};
	if (summary && summary.token_configured)
		tokenOption.description = _('\u5f53\u524d Token \u72b6\u6001\uff1a\u5df2\u914d\u7f6e\u3002\u7559\u7a7a\u4fdd\u6301\u4e0d\u53d8\uff1b\u8f93\u5165\u65b0\u503c\u5c06\u901a\u8fc7 set_token \u66f4\u65b0\u3002');
	else
		tokenOption.description = _('\u5f53\u524d Token \u72b6\u6001\uff1a\u672a\u914d\u7f6e\u3002\u8f93\u5165\u540e\u901a\u8fc7 set_token \u5b89\u5168\u5199\u5165\u3002');

	clearOption = s.taboption('cloudflare', form.Flag, '_clear_token', _('\u6e05\u9664 Token'));
	clearOption.ucisection = 'cloudflare';
	clearOption.default = '0';
	clearOption.cfgvalue = function() { return '0'; };
	clearOption.write = function() {
		/* tokenOption performs the clear operation when this flag is set.
		 * This option must otherwise be a no-op: saving interval/zone/etc.
		 * must never erase an already configured token. */
		return true;
	};
	clearOption.remove = function() { return true; };
	clearOption.description = _('\u52fe\u9009\u540e\u4fdd\u5b58\u5c06\u901a\u8fc7 set_token(clear) \u6e05\u9664 Token');

	o = s.taboption('cloudflare', form.Value, 'zone', _('Zone 域名'));
	o.ucisection = 'cloudflare';
	o.rmempty = false;
	o.placeholder = 'example.com';

	o = s.taboption('cloudflare', form.Value, 'ttl', _('TTL'));
	o.ucisection = 'cloudflare';
	o.datatype = 'uinteger';
	o.default = '1';
	o.description = _('1 表示自动；否则 60–86400 秒');

	o = s.taboption('cloudflare', form.ListValue, 'proxied', _('代理模式'));
	o.ucisection = 'cloudflare';
	o.value('0', _('灰云（仅 DNS）'));
	o.value('1', _('橙云（启用 Cloudflare 代理）'));
	o.default = '0';
	o.rmempty = false;
	o.description = _('灰云直接返回优选 IP；橙云由 Cloudflare 代理流量，可能改变测速 IP 的实际效果。');

	/* speed test → test section */
	o = s.taboption('performance', form.Value, 'threads', _('测速线程'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(1),max(100))';
	o.default = '50';

	o = s.taboption('performance', form.Value, 'attempts', _('延迟测试次数'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(1),max(20))';
	o.default = '4';

	o = s.taboption('performance', form.Value, 'download_count', _('下载候选数'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(1),max(50))';
	o.default = '10';
	o.description = _('需要凑够的达标 IP 数量。测速会跳过达不到最低下载速度的 IP 继续尝试，直到凑够该数量或候选耗尽（受任务超时限制）。');

	o = s.taboption('performance', form.Value, 'download_seconds', _('单节点下载时间（秒）'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(1),max(120))';
	o.default = '10';

	o = s.taboption('performance', form.Value, 'port', _('测速端口'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(1),max(65535))';
	o.default = '443';

	o = s.taboption('performance', form.Value, 'test_url', _('测速 URL'));
	o.ucisection = 'test';
	o.rmempty = false;
	o.description = _('须为 HTTP 或 HTTPS；建议使用自有且位于 Cloudflare 后的下载地址');

	o = s.taboption('performance', form.Value, 'max_latency_ms', _('最高延迟（毫秒）'));
	o.ucisection = 'test';
	o.datatype = 'and(min(1),max(10000))';
	o.default = '200';

	o = s.taboption('performance', form.Value, 'max_loss_ratio', _('最大丢包率'));
	o.ucisection = 'test';
	o.datatype = 'and(min(0),max(1))';
	o.default = '0.2';

	o = s.taboption('performance', form.Value, 'min_speed_mbps', _('最低下载速度（Mbps）'));
	o.ucisection = 'test';
	o.datatype = 'min(0)';
	o.default = '0.01';

	o = s.taboption('performance', form.Value, 'task_timeout_seconds', _('任务超时（秒）'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(30),max(7200))';
	o.default = '900';

	o = s.taboption('sources', form.Value, 'ip_file', _('IP 段文件'));
	o.ucisection = 'test';
	o.default = '/usr/share/cloudflare-speedtest/ip.txt';

	o = s.taboption('sources', form.ListValue, 'ip_source', _('IP 来源'));
	o.ucisection = 'test';
	o.value('cidr', _('Cloudflare IP 段 / 裸 IP 列表'));
	o.value('preferred', _('优选反代'));
	o.default = 'cidr';
	o.rmempty = false;
	o.description = _('使用 cidr 时从 ip_file 读取 Cloudflare CIDR 段并展开为 IPv4 地址；使用优选反代时从反代网址读取 IP。');

	o = s.taboption('sources', form.Value, 'candidate_count', _('随机候选 IP 数量'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(0),max(1000000))';
	o.default = '0';
	o.description = _('0 表示不限制候选数量；若没有符合延迟/丢包条件的 IP，将按 1.5 倍自动扩展候选范围。');

	o = s.taboption('sources', form.Flag, 'test_all', _('测试全部 IP'));
	o.ucisection = 'test';
	o.default = '0';
	o.description = _('忽略随机候选数量，测试来源中的全部 IP。');

	o = s.taboption('performance', form.Flag, 'direct_mode', _('测速走直连'));
	o.ucisection = 'test';
	o.default = '1';
	o.description = _('给测速进程的流量打 0xff 标记，绕过 passwall2 等透明代理。关闭后延迟测的是本地代理的响应时间，结果不可信。');

	o = s.taboption('performance', form.Value, 'publish_switch_margin', _('切换阈值（%）'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(0),max(100))';
	o.default = '20';
	o.description = _('已发布 IP 复测仍合格时，新 IP 速度需高出该百分比才替换，用于减少 DNS 抖动。0 表示总是取最快。');

	o = s.taboption('performance', form.Value, 'speed_weight', _('速度权重（%）'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(0),max(100))';
	o.default = '60';
	o.description = _('优选节点按速度与延迟加权评分，此项为速度占比，其余归延迟。100 表示只看速度，0 表示只看延迟。调低可以更偏向就近机房。');

	o = bindPreferredOption(s.taboption('sources', form.ListValue, 'provider', _('优选反代提供商')));
	o.value('auto', _('自动根据本地运营商选择'));
	o.value('ct', _('电信'));
	o.value('cu', _('联通'));
	o.value('cmcc', _('移动'));
	o.value('custom', _('自定义'));
	o.default = 'auto';
	o.rmempty = false;
	o.description = _('选择仅测试指定的优选反代网址中的 IP。');

	o = bindPreferredOption(s.taboption('sources', form.Value, 'url_ct', _('电信优选 URL')));
	o.default = ['https', '://cf.090227.xyz/ct?ips=20'].join('');
	o.rmempty = false;

	o = bindPreferredOption(s.taboption('sources', form.Value, 'url_cu', _('联通优选 URL')));
	o.default = ['https', '://cf.090227.xyz/cu?ips=20'].join('');
	o.rmempty = false;

	o = bindPreferredOption(s.taboption('sources', form.Value, 'url_cmcc', _('移动优选 URL')));
	o.default = ['https', '://cf.090227.xyz/cmcc?ips=20'].join('');
	o.rmempty = false;

	o = bindPreferredOption(s.taboption('sources', form.Value, 'url_custom', _('自定义优选 URL')));
	o.placeholder = _('填写返回 IPv4 地址列表的 URL');
	o.description = _('URL 应返回 IPv4 地址，每行一个 IP；也支持文本中包含 IP 的格式。');

	o = bindPreferredOption(s.taboption('sources', form.Value, 'timeout', _('优选 URL 超时（秒）')));
	o.datatype = 'and(uinteger,min(1),max(60))';
	o.default = '15';


	/* naming */
	o = s.taboption('naming', form.Value, 'template', _('自定义子域名'));
	o.ucisection = 'naming';
	o.rmempty = false;
	o.default = 'cf';
	o.placeholder = 'cf or edge.node';
	o.description = _('填写相对于 Zone 的自定义子域名，不要填写完整域名；最终会自动拼接为“子域名.Zone”。仅支持小写 ASCII 字母、数字、连字符和点。');

	o = s.taboption('naming', form.DummyValue, '_naming_help', _('\u4f7f\u7528\u8bf4\u660e'));
	o.cfgvalue = function() { return ''; };
	o.render = function() {
		return E('div', { 'class': 'cbi-value-description' },
			_('\u5f53\u524d\u4f7f\u7528\u81ea\u5b9a\u4e49\u5b50\u57df\u540d\u3002\u82e5\u9700\u8981\u81ea\u52a8\u8bc6\u522b\u57ce\u5e02\u548c\u8fd0\u8425\u5546\u6765\u8bbe\u7f6e\u5b50\u57df\u540d\uff0c\u8bf7\u52fe\u9009\u201c\u81ea\u52a8\u8bc6\u522b\u57ce\u5e02\u002f\u8fd0\u8425\u5546\u201d\u3002\u57ce\u5e02\u8986\u76d6\u548c\u8fd0\u8425\u5546\u8986\u76d6\u4f18\u5148\u4e8e\u81ea\u52a8\u8bc6\u522b\uff1b\u56de\u9000\u4ee3\u7801\u4ec5\u5728\u81ea\u52a8\u8bc6\u522b\u4e0d\u53ef\u7528\u65f6\u4f5c\u4e3a\u6700\u540e\u7684\u547d\u540d\u515c\u5e95\u3002'));
	};
	o.write = function() {};
	o.remove = function() { return true; };

	o = s.taboption('naming', form.Flag, 'auto_detect', _('\u81ea\u52a8\u8bc6\u522b\u57ce\u5e02/\u8fd0\u8425\u5546'));
	o.ucisection = 'naming';
	o.default = '1';
	o.description = _('\u52fe\u9009\u540e\uff0c\u4ec5\u4f7f\u7528 UAPIS myip \u67e5\u8be2\u672c\u5730\u516c\u7f51 IP \u7684\u57ce\u5e02\u548c\u8fd0\u8425\u5546\uff0c\u5e76\u4ec5\u5728\u6a21\u677f\u5305\u542b {city} \u6216 {isp} \u65f6\u7528\u4e8e\u751f\u6210\u4e3b\u673a\u540d\u3002');

	o = s.taboption('naming', form.Value, 'city_override', _('\u57ce\u5e02\u8986\u76d6'));
	o.ucisection = 'naming';
	o.optional = true;
	o.placeholder = _('\u4f8b\u5982 sz \u6216 bj');
	o.description = _('\u624b\u52a8\u6307\u5b9a\u57ce\u5e02\u4ee3\u7801\uff0c\u4f18\u5148\u4e8e\u81ea\u52a8\u8bc6\u522b\u3002\u4ec5\u5f53\u6a21\u677f\u5305\u542b {city} \u65f6\u5f71\u54cd DNS \u4e3b\u673a\u540d\uff0c\u4e0d\u6539\u53d8\u201c\u5730\u533a\u4e0e DNS\u201d \u4e2d\u663e\u793a\u7684\u672c\u5730\u5f52\u5c5e\u3002');

	o = s.taboption('naming', form.Value, 'isp_override', _('\u8fd0\u8425\u5546\u8986\u76d6'));
	o.ucisection = 'naming';
	o.optional = true;
	o.placeholder = _('\u4f8b\u5982 ct\u3001cu \u6216 cm');
	o.description = _('\u624b\u52a8\u6307\u5b9a\u8fd0\u8425\u5546\u4ee3\u7801\uff0c\u4f18\u5148\u4e8e\u81ea\u52a8\u8bc6\u522b\u3002\u4ec5\u5f53\u6a21\u677f\u5305\u542b {isp} \u65f6\u5f71\u54cd DNS \u4e3b\u673a\u540d\uff0c\u4e0d\u6539\u53d8\u201c\u5730\u533a\u4e0e DNS\u201d \u4e2d\u663e\u793a\u7684\u672c\u5730\u5f52\u5c5e\u3002');

	o = s.taboption('naming', form.Value, 'fallback_city', _('\u56de\u9000\u57ce\u5e02\u4ee3\u7801'));
	o.ucisection = 'naming';
	o.optional = true;
	o.placeholder = _('\u4f8b\u5982 sz \u6216 bj');
	o.description = _('\u4ec5\u5728\u6ca1\u6709\u57ce\u5e02\u8986\u76d6\u3001\u81ea\u52a8\u8bc6\u522b\u4e0d\u53ef\u7528\u4e14\u6a21\u677f\u9700\u8981 {city} \u65f6\u4f7f\u7528\uff0c\u4f5c\u4e3a\u57ce\u5e02\u547d\u540d\u7684\u6700\u540e\u515c\u5e95\uff1b\u4e0d\u7528\u4e8e\u663e\u793a\u672c\u5730\u5f52\u5c5e\u3002');

	o = s.taboption('naming', form.Value, 'fallback_isp', _('\u56de\u9000\u8fd0\u8425\u5546\u4ee3\u7801'));
	o.ucisection = 'naming';
	o.optional = true;
	o.placeholder = _('\u4f8b\u5982 ct\u3001cu \u6216 cm');
	o.description = _('\u4ec5\u5728\u6ca1\u6709\u8fd0\u8425\u5546\u8986\u76d6\u3001\u81ea\u52a8\u8bc6\u522b\u4e0d\u53ef\u7528\u4e14\u6a21\u677f\u9700\u8981 {isp} \u65f6\u4f7f\u7528\uff0c\u4f5c\u4e3a\u8fd0\u8425\u5546\u547d\u540d\u7684\u6700\u540e\u515c\u5e95\uff1b\u4e0d\u7528\u4e8e\u663e\u793a\u672c\u5730\u5f52\u5c5e\u3002');

	/* Keep the only live log panel inside the logs tab. */
	o = s.taboption('logs', form.Value, '_logs_panel', _('运行日志'));
	o.cfgvalue = function() { return ''; };
	o.render = function() { return renderLogsPanel(view); };
	o.write = function() {};
	o.remove = function() { return true; };

	return m;
}

return view.extend({
	load: function() {
		return Promise.all([
			callStatus(),
			callResult(),
			callConfigSummary(),
			uci.load('cloudflare-speedtest')
		]);
	},

	refreshAll: function() {
		var view = this;
		return Promise.all([
			callStatus(),
			callResult(),
			callConfigSummary()
		]).then(function(results) {
			var status = results[0] || {};
			var result = results[1] || {};
			var summary = results[2] || {};
			view._lastStatus = status;
			view._lastResult = result;
			view._lastSummary = summary;
			/* Keep Stop enabled while an accepted task is still transitioning from
			 * the old terminal status to preparing/active. */
			if (isActivePhase(status.phase)) {
				view._startPending = false;
				view._startObserved = true;
			}
			else if (view._startObserved && /^(success|failed|cancelled|partial_success)$/.test(status.phase || '')) {
				view._startPending = false;
				view._startObserved = false;
			}
			updateCardDom(status, result, summary);
			updateCandidateDom(status);
			if (view._btnStartUpdate)
				setButtonState(view._btnStartUpdate, view._btnStartOnly, view._btnStop, status.phase, view._startPending);
			if (view._logsAuto && view._logsAuto.checked && view._loadLogs)
				return view._loadLogs();
		}).catch(function(err) {
			addDismissibleNotification(null, E('p', {}, String(err)), 'danger');
		});
	},

	render: function(data) {
		var view = this;
		var status = data[0] || {};
		var result = data[1] || {};
		var summary = data[2] || {};

		view._lastStatus = status;
		view._lastResult = result;
		view._lastSummary = summary;
		view._pollActive = isActivePhase(status.phase);

		var cards = renderStatusCards(status, result, summary);
		var actions = renderActions(view);
		setButtonState(view._btnStartUpdate, view._btnStartOnly, view._btnStop, status.phase, view._startPending);

		var map = buildConfigMap(view, summary);
		/* form.Map.render() is asynchronous on LuCI 24.10. Resolve it before
		 * inserting the result into the DOM; otherwise the page displays
		 * literal "[object Promise]" and none of the tabs/fields are visible. */
		return Promise.resolve(map.render()).then(function(mapNode) {
			var root = E('div', { 'class': 'cfst-overview', 'id': 'cfst-overview' }, [
				E('link', {
					'rel': 'stylesheet',
					'type': 'text/css',
					'href': L.resource('view/cloudflare-speedtest/overview.css')
				}),
				renderHeader(status),
				cards,
				actions,
				E('section', { 'class': 'cfst-settings-shell' }, [
					E('div', { 'class': 'cfst-section-head' }, [
						E('div', {}, [
							E('h3', {}, _('设置中心')),
							E('p', {}, _('保存配置不会自动启动测速任务'))
						]),
						E('span', { 'class': 'cfst-count' },
							summary.schedule_enabled === false ? _('定时任务已关闭') :
								_('每 %s 小时').format(fmtValue(summary.interval_hours, '6')))
					]),
					E('div', { 'class': 'cfst-settings-body' }, [ mapNode ])
				])
			]);

			view._loadLogs();

			var pollFn = L.bind(function() {
				return view.refreshAll().then(function() {
					var active = isActivePhase((view._lastStatus || {}).phase);
					if (active !== view._pollActive) {
						view._pollActive = active;
						/* interval switch: 3000ms active / 15000ms idle — restart poll body next tick */
					}
				});
			}, view);

			/* Initial poll cadence: active 3000ms → 3s, idle 15000ms → 15s */
			var intervalSec = view._pollActive ? (POLL_ACTIVE_MS / 1000) : (POLL_IDLE_MS / 1000);
			poll.add(pollFn, intervalSec);

			/* Dual-cadence helper: when phase flips, schedule complementary delay markers */
			view._pollTimer = null;
			var armCadence = function() {
				if (view._pollTimer)
					window.clearTimeout(view._pollTimer);
				var ms = isActivePhase((view._lastStatus || {}).phase) ? POLL_ACTIVE_MS : POLL_IDLE_MS;
				view._pollTimer = window.setTimeout(function() {
					view.refreshAll().finally(armCadence);
				}, ms);
			};
			armCadence();

			return root;
		});
	},

	/* LuCI renders Save / Save & Apply in the standard page footer when these handlers exist. */
	handleSaveApply: function(ev, mode) {
		return this.super('handleSaveApply', arguments);
	},
	handleSave: function(ev) {
		return this.super('handleSave', arguments);
	},
	handleReset: function(ev) {
		return this.super('handleReset', arguments);
	}
});
