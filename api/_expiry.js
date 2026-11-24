// Looks up real expiry dates for domains (via RDAP, the public registry lookup) and SSL certificates.
import tls from 'node:tls';

const HOST_RE = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i;

export function cleanHost(v) {
  return String(v || '').trim().toLowerCase()
    .replace(/^[a-z]+:\/\//, '')   // drop https://
    .replace(/[/:?#].*$/, '')      // drop path, port, query
    .replace(/\.$/, '');
}

const UA = 'RenewalWatch/1.0 (+https://renewalwatch.ca)';
const RDAP_HEADERS = { accept: 'application/rdap+json, application/json', 'user-agent': UA };
let bootstrap = null; // IANA's list of which server answers for each extension, cached while the function stays warm

async function registryServers(tld) {
  if (!bootstrap) {
    const res = await fetch('https://data.iana.org/rdap/dns.json', { headers: { 'user-agent': UA }, signal: AbortSignal.timeout(8000) });
    if (!res.ok) throw new Error(`IANA lookup failed (${res.status})`);
    bootstrap = await res.json();
  }
  const hit = (bootstrap.services || []).find(([tlds]) => tlds.includes(tld));
  return hit ? hit[1] : [];
}

async function rdapGet(url) {
  return fetch(url, { headers: RDAP_HEADERS, redirect: 'follow', signal: AbortSignal.timeout(10000) });
}

export async function domainExpiry(input) {
  const domain = cleanHost(input).replace(/^www\./, '');
  if (!HOST_RE.test(domain)) throw new Error(`"${input}" doesn't look like a domain name`);
  const tld = domain.split('.').pop();

  // Ask the registry directly (as listed by IANA); fall back to the rdap.org forwarding service.
  const urls = [];
  try { for (const base of await registryServers(tld)) urls.push(`${base.replace(/\/?$/, '/')}domain/${domain}`); } catch { /* use fallback */ }
  urls.push(`https://rdap.org/domain/${domain}`);

  let lastStatus = null, notFound = false;
  for (const url of urls) {
    let res;
    try { res = await rdapGet(url); } catch { lastStatus = 'timeout'; continue; }
    if (res.status === 404) { notFound = true; continue; }
    if (!res.ok) { lastStatus = res.status; continue; }
    const data = await res.json();
    const ev = (data.events || []).find(e => /expir/i.test(e.eventAction || ''));
    if (!ev?.eventDate) throw new Error(`The registry for .${tld} doesn't publish expiry dates, so enter this one by hand`);
    return { date: ev.eventDate.slice(0, 10) };
  }
  if (notFound) throw new Error(`${domain} wasn't found at its registry. Check the spelling.`);
  throw new Error(`Couldn't reach the registry for ${domain} (${lastStatus}). Try again later, or enter the date by hand.`);
}

export function sslExpiry(input) {
  const host = cleanHost(input);
  if (!HOST_RE.test(host)) return Promise.reject(new Error(`"${input}" doesn't look like a website address`));
  return new Promise((resolve, reject) => {
    const sock = tls.connect({ host, port: 443, servername: host, rejectUnauthorized: false, timeout: 8000 }, () => {
      const cert = sock.getPeerCertificate();
      sock.end();
      if (!cert?.valid_to) return reject(new Error(`${host} didn't return a certificate`));
      const issuer = [cert.issuer?.O, cert.issuer?.CN].find(x => typeof x === 'string' && x.trim()) || null;
      resolve({ date: new Date(cert.valid_to).toISOString().slice(0, 10), issuer });
    });
    sock.on('timeout', () => { sock.destroy(); reject(new Error(`Timed out connecting to ${host}`)); });
    sock.on('error', e => reject(new Error(`Couldn't connect to ${host} (${e.code || e.message})`)));
  });
}

// Which value to look up for an item, or null if it isn't set up for automatic checks.
export function checkTarget(item) {
  const d = item.details || {};
  if (!d.auto_check) return null;
  if (item.category === 'domain') return { type: 'domain', host: d.domain_name || item.name };
  if (item.category === 'ssl') return { type: 'ssl', host: d.check_host || d.common_name || item.name };
  return null;
}

export function lookup(type, host) {
  return type === 'domain' ? domainExpiry(host) : sslExpiry(host);
}
