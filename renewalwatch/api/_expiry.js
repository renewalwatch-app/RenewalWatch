// Looks up real expiry dates for domains (via RDAP, the public registry lookup) and SSL certificates.
import tls from 'node:tls';

const HOST_RE = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/i;

export function cleanHost(v) {
  return String(v || '').trim().toLowerCase()
    .replace(/^[a-z]+:\/\//, '')   // drop https://
    .replace(/[/:?#].*$/, '')      // drop path, port, query
    .replace(/\.$/, '');
}

export async function domainExpiry(input) {
  const domain = cleanHost(input).replace(/^www\./, '');
  if (!HOST_RE.test(domain)) throw new Error(`"${input}" doesn't look like a domain name`);
  const res = await fetch(`https://rdap.org/domain/${domain}`, {
    headers: { accept: 'application/rdap+json, application/json' },
    redirect: 'follow',
    signal: AbortSignal.timeout(10000),
  });
  if (res.status === 404) throw new Error(`${domain} wasn't found at its registry`);
  if (!res.ok) throw new Error(`Registry lookup for ${domain} failed (error ${res.status})`);
  const data = await res.json();
  const ev = (data.events || []).find(e => /expir/i.test(e.eventAction || ''));
  if (!ev?.eventDate) throw new Error(`The registry for ${domain} doesn't publish an expiry date`);
  return ev.eventDate.slice(0, 10);
}

export function sslExpiry(input) {
  const host = cleanHost(input);
  if (!HOST_RE.test(host)) return Promise.reject(new Error(`"${input}" doesn't look like a website address`));
  return new Promise((resolve, reject) => {
    const sock = tls.connect({ host, port: 443, servername: host, rejectUnauthorized: false, timeout: 8000 }, () => {
      const cert = sock.getPeerCertificate();
      sock.end();
      if (!cert?.valid_to) return reject(new Error(`${host} didn't return a certificate`));
      resolve(new Date(cert.valid_to).toISOString().slice(0, 10));
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
