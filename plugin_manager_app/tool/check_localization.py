#!/usr/bin/env python3
"""Pure source/ARB regression checks; does not load Flutter or open a UI."""
import json
from pathlib import Path
import re

root = Path(__file__).resolve().parents[2]
catalog = root / 'packages/denial_flutter_sdk/lib/l10n'

def load(path):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            assert key not in result, f'Duplicate ARB key: {key}'
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=unique)

en = load(catalog / 'app_en.arb')
zh = load(catalog / 'app_zh.arb')
assert en['@@locale'] == 'en' and zh['@@locale'] == 'zh'
keys = {key for key in en if key.startswith('plugins')}
assert keys and keys == {key for key in zh if key.startswith('plugins')}
for key in keys:
    assert en[key].strip() and zh[key].strip(), key
    metadata = en['@' + key]
    assert metadata['description'], key
    declared = metadata.get('placeholders', {})
    for language in [en, zh]:
        used = set(re.findall(r'\{(\w+)(?:\}|,)', language[key]))
        assert used == set(declared), (key, used, declared)
    for value in declared.values():
        assert value['type'] in {'String', 'int'}, (key, value)
assert ', plural,' in en['pluginsSelectedCount']
assert '{count}' in zh['pluginsSelectedCount']
print(f'PASS {len(keys)} Plugin Manager ARB pairs, metadata, placeholders and selected-count plural')

sources = root / 'plugin_manager_app/lib'
main = (sources / 'main.dart').read_text()
for wiring in [
    'ShellSettings.fromJson(data).localization',
    'locale: localization.localeOverride',
    'supportedLocales: AppLocalizations.supportedLocales',
    'localizationsDelegates: AppLocalizations.localizationsDelegates',
    'onGenerateTitle: (context) => context.l10n.pluginsAppTitle',
]:
    assert wiring in main, wiring
assert 'Locale(' not in main  # No independent locale IDs or language switch.
print('PASS generated SDK delegates and persisted/system locale wiring')

all_source = '\n'.join(path.read_text() for path in sources.glob('*.dart'))
referenced = set(re.findall(r'\bplugins[A-Z]\w*', all_source))
assert referenced == keys, (referenced - keys, keys - referenced)
for path in sources.glob('*.dart'):
    # App-owned prose is not embedded in leaf UI constructors. Diagnostic
    # parsing/protocol values and external metadata are intentionally exempt.
    assert not re.search(r'\b(?:Text|SelectableText)\(\s*[\'\"]', path.read_text()), path
print('PASS every added resource is used and app leaf text is localized')

feedback = (sources / 'localized_feedback.dart').read_text()
backend = (root / 'packages/denial_plugin_manager/lib/src/progress.dart').read_text()
labels = set(re.findall(r"label = '([^']+)';", backend))
labels.update(re.findall(r"=> '([^']+)'", backend))
labels.update({'Compiling Dart sources', 'Optimizing and generating native code',
               'Preparing assets', 'Loading your saved desktop', 'Compiling your desktop'})
for label in labels:
    assert f"'{label}' => l10n." in feedback, label
assert '_ => l10n.pluginsWorking' in feedback
progress = (sources / 'progress_text.dart').read_text()
assert 'label: progressStage(context.l10n, widget.progress)' in progress
assert 'excludeSemantics: true' in progress
assert 'progressDescription(context.l10n, widget.progress, DateTime.now())' in progress
print('PASS backend compilation/composition stages and stable localized accessibility labels')

for filename in ['app_localizations.dart', 'app_localizations_en.dart', 'app_localizations_zh.dart']:
    generated = (catalog / 'generated' / filename).read_text()
    for key in keys:
        assert key in generated, (filename, key)
print('PASS generated interfaces and both locale implementations contain every added key')
