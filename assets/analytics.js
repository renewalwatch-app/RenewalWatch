// Google Analytics 4. Loads only when GA_MEASUREMENT_ID is set in the hosting settings.
// Never send personal information (emails, names, item details) in events.
let ready = false;

export function initAnalytics(id, { autoPageView = true } = {}) {
  if (ready || !/^G-[A-Z0-9]+$/i.test(id || '')) return;
  ready = true;
  window.dataLayer = window.dataLayer || [];
  window.gtag = function () { window.dataLayer.push(arguments); };
  window.gtag('js', new Date());
  window.gtag('config', id, {
    send_page_view: autoPageView,
    allow_google_signals: false,              // no cross-device advertising profiles
    allow_ad_personalization_signals: false,  // no ad personalization
  });
  const s = document.createElement('script');
  s.async = true;
  s.src = `https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(id)}`;
  document.head.appendChild(s);
}

export function track(event, params = {}) {
  if (ready && window.gtag) window.gtag('event', event, params);
}

export function trackPage(path, title) {
  track('page_view', { page_path: path, page_location: location.origin + path, page_title: title });
}
