// Shared by the browser app and the server functions.
export const FREE_ITEM_LIMIT = 25;

// Field types: text, number, date, select (with options), url, checkbox
const f = (k, label, type = 'text', extra = {}) => ({ k, label, type, ...extra });

export const GROUPS = [
  'Hardware',
  'Servers & Infrastructure',
  'Software & Cloud',
  'Internet-facing',
  'Contracts & Vendors',
  'Operations',
];

export const CATEGORIES = [
  // ---------- FREE: hardware and warranties ----------
  { id: 'computer', label: 'Computer (laptop / desktop)', group: 'Hardware', tier: 'free', dateLabel: 'Warranty ends',
    fields: [f('os', 'Operating system'), f('cpu', 'CPU'), f('ram', 'RAM'), f('storage', 'Storage'), f('hostname', 'Hostname'), f('purchased_from', 'Purchased from')] },
  { id: 'peripheral', label: 'Monitor / dock / peripheral', group: 'Hardware', tier: 'free', dateLabel: 'Warranty ends',
    fields: [f('size_spec', 'Size / spec')] },
  { id: 'printer', label: 'Printer / copier / scanner', group: 'Hardware', tier: 'free', dateLabel: 'Warranty / service ends',
    fields: [f('ip', 'IP address'), f('toner', 'Toner / supplies model'), f('service_contact', 'Service contact')] },
  { id: 'mobile', label: 'Phone / tablet', group: 'Hardware', tier: 'free', dateLabel: 'Warranty / contract ends',
    fields: [f('phone_number', 'Phone number'), f('carrier', 'Carrier'), f('imei', 'IMEI'), f('plan', 'Plan')] },
  { id: 'warranty', label: 'Extended warranty / coverage', group: 'Hardware', tier: 'free', dateLabel: 'Coverage ends',
    fields: [f('covers', 'What it covers'), f('contract_no', 'Contract / claim number'), f('claim_phone', 'Claim phone')] },
  { id: 'other_hw', label: 'Other hardware', group: 'Hardware', tier: 'free', dateLabel: 'Key date', fields: [] },

  // ---------- PRO: servers and infrastructure ----------
  { id: 'server', label: 'Physical server', group: 'Servers & Infrastructure', tier: 'pro', dateLabel: 'Support / warranty ends',
    fields: [f('hostname', 'Hostname'), f('ip', 'IP address'), f('role', 'Role (DC, file, SQL, hypervisor…)'), f('os', 'Operating system'),
      f('os_eos', 'OS end of support', 'date'), f('cpu', 'CPU'), f('ram', 'RAM'), f('storage', 'Storage / RAID'),
      f('mgmt_ip', 'iDRAC / iLO / IPMI address'), f('rack', 'Rack / room location'), f('backup_method', 'Backup method'),
      f('last_patched', 'Last patched', 'date')] },
  { id: 'vm', label: 'Virtual machine', group: 'Servers & Infrastructure', tier: 'pro', dateLabel: 'Review / renewal date',
    fields: [f('hostname', 'Hostname'), f('ip', 'IP address'), f('host', 'Host / cluster'), f('role', 'Role'), f('os', 'Operating system'),
      f('os_eos', 'OS end of support', 'date'), f('vcpu', 'vCPU'), f('ram', 'RAM'), f('backup_method', 'Backup method'),
      f('last_patched', 'Last patched', 'date')] },
  { id: 'network', label: 'Network device (firewall / switch / AP)', group: 'Servers & Infrastructure', tier: 'pro', dateLabel: 'Support / subscription ends',
    fields: [f('device_type', 'Type', 'select', { options: ['Firewall', 'Switch', 'Access point', 'Router', 'Controller', 'Other'] }),
      f('hostname', 'Hostname'), f('mgmt_ip', 'Management IP'), f('firmware', 'Firmware version'),
      f('last_firmware', 'Last firmware update', 'date'), f('license_tier', 'License / security bundle')] },
  { id: 'storage', label: 'Storage (NAS / SAN)', group: 'Servers & Infrastructure', tier: 'pro', dateLabel: 'Support ends',
    fields: [f('hostname', 'Hostname'), f('ip', 'IP address'), f('capacity', 'Capacity'), f('raid', 'RAID level'), f('firmware', 'Firmware version')] },
  { id: 'ups', label: 'UPS / battery backup', group: 'Servers & Infrastructure', tier: 'pro', dateLabel: 'Battery replacement due',
    fields: [f('protects', 'What it protects'), f('runtime', 'Runtime (minutes)', 'number'), f('mgmt_ip', 'Management IP'),
      f('last_self_test', 'Last self-test', 'date')] },
  { id: 'backup', label: 'Backup / disaster recovery', group: 'Servers & Infrastructure', tier: 'pro', dateLabel: 'Next restore test due',
    fields: [f('protects', 'What is backed up'), f('destination', 'Destination (NAS, cloud, tape…)'), f('schedule', 'Schedule'),
      f('retention', 'Retention'), f('last_success', 'Last successful backup', 'date'), f('last_restore_test', 'Last restore test', 'date')] },

  // ---------- PRO: software and cloud ----------
  { id: 'software', label: 'Software license', group: 'Software & Cloud', tier: 'pro', dateLabel: 'Renews / expires',
    fields: [f('license_type', 'License type', 'select', { options: ['Subscription', 'Perpetual', 'Perpetual + maintenance', 'Volume'] }),
      f('version', 'Version'), f('seats_total', 'Seats purchased', 'number'), f('seats_used', 'Seats in use', 'number'),
      f('license_ref', 'License reference (not the key)'), f('admin_portal', 'Admin portal URL', 'url')] },
  { id: 'saas', label: 'SaaS subscription (M365, Google, Adobe…)', group: 'Software & Cloud', tier: 'pro', dateLabel: 'Renews on',
    fields: [f('plan_tier', 'Plan / tier'), f('seats_total', 'Seats purchased', 'number'), f('seats_used', 'Seats in use', 'number'),
      f('account_owner', 'Account owner'), f('admin_portal', 'Admin portal URL', 'url')] },
  { id: 'security', label: 'Security service (EDR, email filter, MFA)', group: 'Software & Cloud', tier: 'pro', dateLabel: 'Renews on',
    fields: [f('product', 'Product'), f('coverage', 'What it covers'), f('seats_total', 'Seats purchased', 'number'),
      f('seats_used', 'Seats in use', 'number'), f('admin_portal', 'Admin portal URL', 'url')] },
  { id: 'cloud', label: 'Cloud / hosting account', group: 'Software & Cloud', tier: 'pro', dateLabel: 'Commitment / renewal date',
    fields: [f('provider', 'Provider'), f('account_id', 'Account / tenant ID'), f('monthly_budget', 'Monthly budget', 'number'),
      f('admin_portal', 'Admin portal URL', 'url')] },

  // ---------- PRO: internet-facing ----------
  { id: 'domain', label: 'Domain name', group: 'Internet-facing', tier: 'pro', dateLabel: 'Expires',
    fields: [f('auto_check', 'Look up the expiry date automatically every day', 'checkbox'), f('domain_name', 'Domain to check (e.g. company.ca)'),
      f('registrar', 'Registrar'), f('dns_host', 'DNS host'), f('registrant', 'Registrant account')] },
  { id: 'ssl', label: 'SSL / TLS certificate', group: 'Internet-facing', tier: 'pro', dateLabel: 'Expires',
    fields: [f('auto_check', 'Check the certificate automatically every day', 'checkbox'), f('check_host', 'Website to check (e.g. www.company.ca)'),
      f('common_name', 'Common name'), f('sans', 'Other names (SANs)'), f('issuer', 'Issuer'), f('installed_on', 'Installed on')] },

  // ---------- PRO: contracts and vendors ----------
  { id: 'support_contract', label: 'Support / maintenance contract', group: 'Contracts & Vendors', tier: 'pro', dateLabel: 'Contract ends',
    fields: [f('contract_no', 'Contract number'), f('coverage_level', 'Coverage level (NBD, 4hr…)'), f('covers', 'What it covers'),
      f('support_phone', 'Support phone')] },
  { id: 'isp', label: 'Internet / telecom circuit', group: 'Contracts & Vendors', tier: 'pro', dateLabel: 'Contract ends',
    fields: [f('provider', 'Provider'), f('circuit_id', 'Circuit ID'), f('account_no', 'Account number'), f('speed', 'Speed'),
      f('static_ips', 'Static IPs'), f('support_phone', 'Support phone')] },
  { id: 'phone_system', label: 'Phone system / VoIP', group: 'Contracts & Vendors', tier: 'pro', dateLabel: 'Contract ends',
    fields: [f('provider', 'Provider'), f('account_no', 'Account number'), f('lines', 'Lines / extensions', 'number'), f('support_phone', 'Support phone')] },
  { id: 'lease', label: 'Equipment lease / rental', group: 'Contracts & Vendors', tier: 'pro', dateLabel: 'Lease ends',
    fields: [f('lessor', 'Leasing company'), f('lease_no', 'Lease number'), f('buyout', 'Buyout amount', 'number')] },
  { id: 'compliance', label: 'Compliance / cyber insurance / audit', group: 'Contracts & Vendors', tier: 'pro', dateLabel: 'Due / renews',
    fields: [f('kind', 'Type (insurance, PCI scan, audit…)'), f('provider', 'Provider'), f('policy_no', 'Policy / reference number')] },

  // ---------- PRO: operations ----------
  { id: 'task', label: 'Recurring IT task', group: 'Operations', tier: 'pro', dateLabel: 'Next due',
    fields: [f('checklist', 'Steps / checklist')] },
];

export const CAT = Object.fromEntries(CATEGORIES.map(c => [c.id, c]));
export const FREE_CATEGORY_IDS = CATEGORIES.filter(c => c.tier === 'free').map(c => c.id);
export const isFreeCategory = id => FREE_CATEGORY_IDS.includes(id);

// Extra dates (besides the main key date) that should trigger reminders.
export const EXTRA_REMINDER_DATES = [{ k: 'os_eos', label: 'OS end of support' }];

export const STATUSES = [
  { id: 'active', label: 'In use' },
  { id: 'spare', label: 'Spare / in storage' },
  { id: 'repair', label: 'In repair' },
  { id: 'retired', label: 'Retired' },
];

export const BILLING = [
  { id: 'one_time', label: 'One-time' },
  { id: 'monthly', label: 'Monthly' },
  { id: 'annual', label: 'Annual' },
  { id: 'multi_year', label: 'Multi-year' },
];
