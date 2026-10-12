/* ============================================================
   Fallback config — only needed if you are NOT using .env + Node.

   Preferred route:   cp .env.example .env  →  npm run config
   Manual route:      cp config.example.js config.js  →  edit below

   Either way the result is a gitignored `config.js` that the
   HTML pages load. Never commit it.
   ============================================================ */

window.ICON_CONFIG = {
  // Settings -> Data API -> Project URL
  SUPABASE_URL: 'https://YOUR_PROJECT_REF.supabase.co',

  // Settings -> API Keys -> Publishable key (a.k.a. anon public)
  // Safe in the browser. Never paste the secret / service_role key here.
  SUPABASE_KEY: 'YOUR_PUBLISHABLE_KEY',

  // Which row in the `salons` table this install serves
  SALON_ID: 1,

  // Average minutes per haircut
  MINUTES_PER_CLIENT: 15,

  // Number of stylist chairs currently running
  ACTIVE_CHAIRS: 1
};
