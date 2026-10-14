-- Apply to staging first; promote the same migration after acceptance.
-- Only enable catalog v1 combinations, not future additions or voice profiles.
begin;

update public.language_capabilities_v1 as capability
set can_generate = true
from (values
  ('en', 'zh-Hans', 'en-US'),
  ('en', 'es', 'en-US'),
  ('en', 'ja', 'en-US'),
  ('en', 'fr', 'en-US'),
  ('es', 'zh-Hans', 'es-419'),
  ('es', 'en', 'es-419'),
  ('ja', 'zh-Hans', 'ja-JP'),
  ('ja', 'en', 'ja-JP'),
  ('fr', 'zh-Hans', 'fr-FR'),
  ('fr', 'en', 'fr-FR')
) as supported(target_language, translation_language, teaching_locale)
where capability.target_language = supported.target_language
  and capability.translation_language = supported.translation_language
  and capability.teaching_locale = supported.teaching_locale
  and not capability.can_generate;

commit;
