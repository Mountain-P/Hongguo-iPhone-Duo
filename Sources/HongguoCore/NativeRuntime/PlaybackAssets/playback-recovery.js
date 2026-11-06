// SPDX-License-Identifier: GPL-3.0-only
// Protocol contract checked against aston314/hongguo-tv 36508246eeca2cf5ef1f29f7f17f8e985d50ae2e.
// Anonymous video_tab identity is separate from each legacy POST resolution.
const LEGACY_HOSTS = Object.freeze(['api5-normal-sinfonlineb.fqnovel.com', 'api5-normal-hl.fqnovel.com']);
const RETRYABLE_HTTP = new Set([408, 425, 429, 500, 502, 503, 504]);
const RETRYABLE_NETWORK = new Set(['ETIMEDOUT', 'ECONNABORTED', 'ENOTFOUND', 'EAI_AGAIN', 'ECONNRESET', 'ECONNREFUSED', 'EHOSTUNREACH', 'ENETUNREACH', 'EPIPE', 'ERR_NETWORK']);

function failure(code, message) { return Object.assign(new Error(message), { code }); }
function checkActive(signal, deadline, now = Date.now) {
    if (signal?.aborted) throw signal.reason || failure('ABORT_ERR', '播放准备已取消');
    if (now() >= deadline) throw failure('ETIMEDOUT', '播放准备超时，请重试');
}
function terminal(error) {
    return [401, 403].includes(Number(error?.status))
        || ['BUSINESS_REJECTED', 'SECURITY_BLOCKED', 'NO_COMPATIBLE_SOURCE', 'QUALITY_UNAVAILABLE'].includes(error?.code)
        || ['BUSINESS_REJECTED', 'SECURITY_BLOCKED'].includes(error?.registrationFailure);
}
function retryable(error) {
    if (error?.stage && error.stage !== 'multi_video_model') return false;
    return error?.code === 'EMPTY_RESPONSE' && Number(error.status) === 200
        || RETRYABLE_NETWORK.has(error?.code) || RETRYABLE_HTTP.has(Number(error?.status));
}

function normalizeVideoTabEnvelope(vid, response) {
    if (Number(response?.Code || response?.code || 0) !== 0) throw failure('BUSINESS_REJECTED', '来源未授权提供本集播放信息');
    const rows = response?.data?.video_model_data || response?.data;
    // Never substitute the first unrelated result for the requested episode.
    const entry = rows?.[vid];
    if (!entry || !entry.video_model) throw failure('MISSING_MODEL', '来源未返回所选分集');
    return { code: 0, data: { [vid]: entry } };
}

function createPlaybackRecovery({ register, getModel, postModel, consume, now = Date.now, tabTTL = 300000 }) {
    let tabIdentity;
    let tabIdentityExpires = 0;
    return async function resolve(vid, { signal, deadline = now() + 30000, contentType = '1004', options = {} } = {}) {
        checkActive(signal, deadline, now);
        let lastError;
        try {
            if (!tabIdentity || tabIdentityExpires <= now()) {
                const identity = await register({ scope: 'tab', signal, deadline });
                checkActive(signal, deadline, now);
                tabIdentity = identity;
                tabIdentityExpires = now() + tabTTL;
            }
            const response = normalizeVideoTabEnvelope(vid, await getModel(vid, tabIdentity, { signal, deadline }));
            checkActive(signal, deadline, now);
            const value = await consume(response, vid, options, { signal, deadline });
            checkActive(signal, deadline, now);
            return { value, recovery: { route: 'video_tab', attempts: 1 } };
        } catch (error) {
            checkActive(signal, deadline, now);
            if (terminal(error)) throw error;
            lastError = error;
        }
        let attempts = 0;
        for (let round = 0; round < 2; round++) {
            checkActive(signal, deadline, now);
            let identity;
            try { identity = await register({ scope: 'legacy', signal, deadline }); }
            catch (error) {
                checkActive(signal, deadline, now);
                if (terminal(error)) throw error;
                lastError = error;
                continue;
            }
            for (let hostIndex = 0; hostIndex < LEGACY_HOSTS.length; hostIndex++) {
                checkActive(signal, deadline, now);
                attempts++;
                try {
                    // The dependency builds and signs the FINAL bytes/query anew for every host.
                    const response = await postModel(vid, contentType, identity, LEGACY_HOSTS[hostIndex], { signal, deadline, hostIndex });
                    checkActive(signal, deadline, now);
                    const value = await consume(response, vid, options, { signal, deadline });
                    checkActive(signal, deadline, now);
                    return { value, recovery: { route: 'registered_post', attempts, round: round + 1 } };
                } catch (error) {
                    checkActive(signal, deadline, now);
                    if (!retryable(error) || terminal(error)) throw error;
                    lastError = error;
                }
            }
        }
        throw lastError || failure('MISSING_MODEL', '来源暂未提供本集影片');
    };
}

module.exports = { createPlaybackRecovery, normalizeVideoTabEnvelope, checkActive, LEGACY_HOSTS };
