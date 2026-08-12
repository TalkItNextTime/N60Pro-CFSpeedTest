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
	testing_latency: true,
	testing_download: true,
	validating_result: true,
	updating_dns: true,
	cleaning_old_record: true
};

function isActivePhase(phase) {
	return !!(phase && ACTIVE_PHASES[phase]);
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
	ui.addNotification(null, E('p', {}, text), 'danger');
}

function notifyOk(message) {
	ui.addNotification(null, E('p', {}, message), 'info');
}

function fmtValue(v, fallback) {
	if (v === null || v === undefined || v === '')
		return fallback || '—';
	return String(v);
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
	var nextRun = status.next_run_at || status.next_run || summary.next_run_at || '—';
	var tested = result.last_tested || {};
	var published = result.last_published || {};
	var managed = result.managed_record || {};
	var geo = result.geo_cache || status.geo || {};

	var cardRun = E('div', { 'class': 'status-card cbi-section' }, [
		E('h3', {}, _('运行状态')),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('阶段')),
			E('div', { 'class': 'cbi-value-field', 'id': 'cfst-phase' }, fmtValue(phase))
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('消息')),
			E('div', { 'class': 'cbi-value-field', 'id': 'cfst-message' }, fmtValue(message, _('空闲')))
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('下次任务')),
			E('div', { 'class': 'cbi-value-field', 'id': 'cfst-next-run' }, fmtValue(nextRun))
		])
	]);

	var cardNode = E('div', { 'class': 'status-card cbi-section' }, [
		E('h3', {}, _('优选节点')),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('最近测速 IP')),
			E('div', { 'class': 'cbi-value-field', 'id': 'cfst-last-tested-ip' }, fmtObjectField(tested, 'ip'))
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('延迟 / 速度')),
			E('div', { 'class': 'cbi-value-field', 'id': 'cfst-last-tested-metrics' },
				fmtObjectField(tested, 'latency_ms') + ' ms / ' + fmtObjectField(tested, 'speed_mbps') + ' Mbps')
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('最近发布 IP')),
			E('div', { 'class': 'cbi-value-field', 'id': 'cfst-last-published-ip' }, fmtObjectField(published, 'ip'))
		]),
		E('p', { 'class': 'cbi-value-description' },
			_('last_tested 为最近一次测速结果；last_published 为已写入 DNS 的结果，二者可能不同。'))
	]);

	var cardDns = E('div', { 'class': 'status-card cbi-section' }, [
		E('h3', {}, _('地区与 DNS')),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('归属')),
			E('div', { 'class': 'cbi-value-field', 'id': 'cfst-geo' },
				fmtObjectField(geo, 'city') + ' / ' + fmtObjectField(geo, 'isp'))
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('管理记录')),
			E('div', { 'class': 'cbi-value-field', 'id': 'cfst-managed' },
				fmtObjectField(managed, 'name') || fmtObjectField(published, 'hostname') || '—')
		]),
		E('div', { 'class': 'cbi-value' }, [
			E('label', { 'class': 'cbi-value-title' }, _('Token')),
			E('div', { 'class': 'cbi-value-field', 'id': 'cfst-token-state' },
				summary.token_configured ? _('已配置') : _('未配置'))
		])
	]);

	return E('div', { 'class': 'cbi-section-node', 'style': 'display:flex;flex-wrap:wrap;gap:1em' }, [
		cardRun, cardNode, cardDns
	]);
}

function setButtonState(btnStartUpdate, btnStartOnly, btnStop, phase) {
	var active = isActivePhase(phase);
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
	var geo = result.geo_cache || status.geo || {};

	var setText = function(id, text) {
		var el = document.getElementById(id);
		if (el)
			el.textContent = text;
	};

	setText('cfst-phase', fmtValue(status.phase, 'idle'));
	setText('cfst-message', fmtValue(status.message, _('空闲')));
	setText('cfst-next-run', fmtValue(status.next_run_at || status.next_run || summary.next_run_at));
	setText('cfst-last-tested-ip', fmtObjectField(tested, 'ip'));
	setText('cfst-last-tested-metrics',
		fmtObjectField(tested, 'latency_ms') + ' ms / ' + fmtObjectField(tested, 'speed_mbps') + ' Mbps');
	setText('cfst-last-published-ip', fmtObjectField(published, 'ip'));
	setText('cfst-geo', fmtObjectField(geo, 'city') + ' / ' + fmtObjectField(geo, 'isp'));
	setText('cfst-managed', fmtObjectField(managed, 'name') || fmtObjectField(published, 'hostname') || '—');
	setText('cfst-token-state', summary.token_configured ? _('已配置') : _('未配置'));
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
		btnStartUpdate.disabled = true;
		btnStartOnly.disabled = true;
		return callStart('test-and-update').then(function(res) {
			if (res && res.error_code) {
				notifyError(res);
				return;
			}
			if (res && res.accepted === false) {
				notifyError(res);
				return;
			}
			notifyOk(_('已接受：测速并更新 DNS（test-and-update）'));
			return view.refreshAll();
		}).catch(function(err) {
			notifyError({ error_message: String(err) });
		});
	});

	btnStartOnly.addEventListener('click', function() {
		btnStartUpdate.disabled = true;
		btnStartOnly.disabled = true;
		return callStart('test-only').then(function(res) {
			if (res && res.error_code) {
				notifyError(res);
				return;
			}
			if (res && res.accepted === false) {
				notifyError(res);
				return;
			}
			notifyOk(_('已接受：仅测速（test-only）'));
			return view.refreshAll();
		}).catch(function(err) {
			notifyError({ error_message: String(err) });
		});
	});

	btnStop.addEventListener('click', function() {
		return callStop().then(function(res) {
			if (res && res.error_code) {
				notifyError(res);
				return;
			}
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

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, _('手动操作')),
		E('div', { 'class': 'cbi-page-actions', 'style': 'display:flex;flex-wrap:wrap;gap:0.5em' }, [
			btnStartUpdate, btnStartOnly, btnStop, btnValidate
		])
	]);
}

function renderLogsPanel(view) {
	var pre = E('pre', {
		'id': 'cfst-logs',
		'style': 'max-height:24em;overflow:auto;white-space:pre-wrap;word-break:break-all'
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

	return E('div', { 'class': 'cbi-section' }, [
		E('h3', {}, _('运行日志')),
		E('p', {}, _('单次读取上限 65536 字节；仅支持 clear_logs 清空插件日志。')),
		E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:0.5em;align-items:center;margin-bottom:0.5em' }, [
			btnRefresh, btnClear,
			E('label', {}, [ autoRefresh, ' ', _('自动刷新') ])
		]),
		pre
	]);
}

function buildConfigMap(view, summary) {
	var m = new form.Map('cloudflare-speedtest', _('配置'),
		_('保存配置不会自动启动测速；请使用上方手动操作按钮。'));

	m.chain('cloudflare-speedtest');

	var s = m.section(form.NamedSection, 'main', 'main', _('插件配置'));
	s.addremove = false;
	s.anonymous = false;

	s.tab('basic', _('基本设置'));
	s.tab('cloudflare', _('Cloudflare DNS'));
	s.tab('speedtest', _('测速参数'));
	s.tab('naming', _('地区命名'));
	s.tab('logs', _('运行日志'));

	var o;

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

	/* Cloudflare section fields target ucisection cloudflare */
	o = s.taboption('cloudflare', form.PasswordValue, '_api_token', _('API Token'));
	o.password = true;
	o.optional = true;
	o.rmempty = true;
	o.placeholder = _('已配置；留空保持不变');
	o.ucisection = 'cloudflare';
	o.cfgvalue = function() {
		/* Never load secret via ordinary UCI; only show empty + placeholder when token_configured */
		return '';
	};
	o.write = function() {
		/* Token saved exclusively through set_token RPC */
		return true;
	};
	o.remove = function() {
		return true;
	};
	if (summary && summary.token_configured)
		o.description = _('当前 Token 状态：已配置。留空保持不变；输入新值将通过 set_token 更新。');
	else
		o.description = _('当前 Token 状态：未配置。输入后通过 set_token 安全写入。');

	o = s.taboption('cloudflare', form.Flag, '_clear_token', _('清除 Token'));
	o.ucisection = 'cloudflare';
	o.default = '0';
	o.cfgvalue = function() { return '0'; };
	o.write = function() { return true; };
	o.remove = function() { return true; };
	o.description = _('勾选后保存将通过 set_token(clear) 清除 Token');

	o = s.taboption('cloudflare', form.Value, 'zone', _('Zone 域名'));
	o.ucisection = 'cloudflare';
	o.rmempty = false;
	o.placeholder = 'example.com';

	o = s.taboption('cloudflare', form.Value, 'ttl', _('TTL'));
	o.ucisection = 'cloudflare';
	o.datatype = 'uinteger';
	o.default = '1';
	o.description = _('1 表示自动；否则 60–86400 秒');

	o = s.taboption('cloudflare', form.DummyValue, '_proxy_note', _('代理模式'));
	o.ucisection = 'cloudflare';
	o.cfgvalue = function() {
		return _('固定灰云（仅 DNS）。橙云代理已禁用：橙云会终止在 Cloudflare 边缘，无法把优选 IP 解析给客户端。');
	};

	/* speed test → test section */
	o = s.taboption('speedtest', form.Value, 'threads', _('测速线程'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(1),max(100))';
	o.default = '50';

	o = s.taboption('speedtest', form.Value, 'attempts', _('延迟测试次数'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(1),max(20))';
	o.default = '4';

	o = s.taboption('speedtest', form.Value, 'download_count', _('下载候选数'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(1),max(50))';
	o.default = '5';

	o = s.taboption('speedtest', form.Value, 'download_seconds', _('单节点下载时间（秒）'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(1),max(120))';
	o.default = '10';

	o = s.taboption('speedtest', form.Value, 'port', _('测速端口'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(1),max(65535))';
	o.default = '443';

	o = s.taboption('speedtest', form.Value, 'test_url', _('测速 URL'));
	o.ucisection = 'test';
	o.rmempty = false;
	o.description = _('须为 HTTP 或 HTTPS；建议使用自有且位于 Cloudflare 后的下载地址');

	o = s.taboption('speedtest', form.Value, 'max_latency_ms', _('最高延迟（毫秒）'));
	o.ucisection = 'test';
	o.datatype = 'and(min(1),max(10000))';
	o.default = '200';

	o = s.taboption('speedtest', form.Value, 'max_loss_ratio', _('最大丢包率'));
	o.ucisection = 'test';
	o.datatype = 'and(min(0),max(1))';
	o.default = '0.2';

	o = s.taboption('speedtest', form.Value, 'min_speed_mbps', _('最低下载速度（Mbps）'));
	o.ucisection = 'test';
	o.datatype = 'min(0)';
	o.default = '0.01';

	o = s.taboption('speedtest', form.Value, 'task_timeout_seconds', _('任务超时（秒）'));
	o.ucisection = 'test';
	o.datatype = 'and(uinteger,min(30),max(7200))';
	o.default = '900';

	o = s.taboption('speedtest', form.Value, 'ip_file', _('IP 段文件'));
	o.ucisection = 'test';
	o.default = '/usr/share/cloudflare-speedtest/ip.txt';

	/* naming */
	o = s.taboption('naming', form.Value, 'template', _('命名模板'));
	o.ucisection = 'naming';
	o.default = '{city}{isp}.{zone}';

	o = s.taboption('naming', form.Flag, 'auto_detect', _('自动识别城市/运营商'));
	o.ucisection = 'naming';
	o.default = '1';

	o = s.taboption('naming', form.Value, 'city_override', _('城市覆盖'));
	o.ucisection = 'naming';
	o.optional = true;

	o = s.taboption('naming', form.Value, 'isp_override', _('运营商覆盖'));
	o.ucisection = 'naming';
	o.optional = true;

	o = s.taboption('naming', form.Value, 'fallback_city', _('回退城市代码'));
	o.ucisection = 'naming';
	o.optional = true;

	o = s.taboption('naming', form.Value, 'fallback_isp', _('回退运营商代码'));
	o.ucisection = 'naming';
	o.optional = true;

	/* logs tab: pointer to live panel (rendered outside map for polling) */
	o = s.taboption('logs', form.DummyValue, '_logs_help', _('说明'));
	o.cfgvalue = function() {
		return _('日志面板位于页面底部，支持手动/自动刷新与 clear_logs。');
	};

	var tokenOption = null;
	var clearOption = null;
	m.findElement = m.findElement; /* keep reference */

	var origSave = m.save;
	m.save = function() {
		var self = this;
		var tokenInput = self.map ? null : null;
		var tokenVal = '';
		var clearVal = false;

		var nodes = self.renderContents ? null : null;
		void nodes;
		void tokenInput;

		/* Read widget values from DOM after form serialize path */
		var tokenEl = document.querySelector('[id$="._api_token"]') ||
			document.querySelector('input[data-name="_api_token"]') ||
			document.getElementById(self.prepend ? '' : '');
		/* Fallback: scan password inputs in this map */
		if (!tokenEl) {
			var passwords = document.querySelectorAll('input[type="password"]');
			if (passwords && passwords.length)
				tokenEl = passwords[0];
		}
		if (tokenEl)
			tokenVal = tokenEl.value || '';

		var clearEl = document.querySelector('input[type="checkbox"][data-name="_clear_token"], input[name$="._clear_token"]');
		if (!clearEl) {
			/* best-effort: look for clear flag near token */
			var flags = document.querySelectorAll('input[type="checkbox"]');
			for (var i = 0; i < flags.length; i++) {
				var id = flags[i].id || flags[i].name || '';
				if (id.indexOf('_clear_token') !== -1) {
					clearEl = flags[i];
					break;
				}
			}
		}
		if (clearEl)
			clearVal = !!(clearEl.checked || clearEl.value === '1');

		var tokenPromise = Promise.resolve();
		if (clearVal) {
			tokenPromise = callSetToken('', true).then(function(res) {
				if (res && res.error_code)
					notifyError(res);
				else
					notifyOk(_('Token 已清除'));
			});
		}
		else if (tokenVal) {
			tokenPromise = callSetToken(tokenVal, false).then(function(res) {
				if (res && res.error_code)
					notifyError(res);
				else
					notifyOk(_('Token 已通过 set_token 更新'));
			});
		}

		return tokenPromise.then(function() {
			if (typeof origSave === 'function')
				return origSave.apply(self, arguments);
			return form.Map.prototype.save.apply(self, arguments);
		}).then(function(res) {
			if (tokenEl)
				tokenEl.value = '';
			return view.refreshAll().then(function() { return res; });
		});
	};

	void tokenOption;
	void clearOption;

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
			updateCardDom(status, result, summary);
			if (view._btnStartUpdate)
				setButtonState(view._btnStartUpdate, view._btnStartOnly, view._btnStop, status.phase);
			if (view._logsAuto && view._logsAuto.checked && view._loadLogs)
				return view._loadLogs();
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, String(err)), 'danger');
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
		setButtonState(view._btnStartUpdate, view._btnStartOnly, view._btnStop, status.phase);

		var map = buildConfigMap(view, summary);
		var logs = renderLogsPanel(view);

		var root = E('div', { 'class': 'cbi-map', 'id': 'cfst-overview' }, [
			E('h2', {}, _('Cloudflare 优选 IP')),
			E('p', {}, _('单页仪表盘：状态、手动操作、配置与日志。页面关闭不影响后台任务。')),
			cards,
			actions,
			E('div', { 'class': 'cbi-section-node' }, [ map.render() ]),
			logs
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
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
