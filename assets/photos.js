/* ============================================================
   ICON — photo manifest
   Every picture slot on the customer site reads from this list. A
   key with no entry shows a tonal plate instead, so the site works
   with no photos at all. To add a photo: put the file in assets/,
   then add a line here. No other change is needed.

   Keys:
     'hero'                       directory hero (wide, about 16:9)
     'category:<slug>'            a category, e.g. 'category:barbers'
     'shop:<slug>'                a shop's hero, e.g. 'shop:fade-factory'
     'service:<category>'         services of a type: hair, beard,
                                  nails, skin, spa, other
     'staff:<shop-slug>:<name>'   a team member, e.g. 'staff:fade-factory:imran'

   Use your own photographs, or ones you have the rights to.
   Landscape for heroes, portrait (4:5) for people and services.
   Keep each file under ~300 KB (WebP or JPEG at 1600px wide).
   ============================================================ */

window.ICON_PHOTOS = {
  // 'hero': 'assets/hero.jpg',
  // 'shop:fade-factory': 'assets/shops/fade-factory.jpg',
  // 'service:hair': 'assets/services/hair.jpg',
  // 'staff:fade-factory:imran': 'assets/staff/imran.jpg'
};
