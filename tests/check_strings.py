"""Every UI string in src/ must be translated, with matching format specifiers.

L(@"...")  -> Resources/pl.lproj/Localizable.strings
LN(@"...") -> Resources/{en,pl}.lproj/Localizable.stringsdict
"""
import glob
import json
import plistlib
import re
import subprocess
import sys

KEY = r'"((?:[^"\\]|\\.)*)"'
SPEC = re.compile(r'%(?:\d+\$)?(?:l?[du]|@|\.0f|%)')


def source_keys(macro):
    keys = set()
    for path in glob.glob('src/*.[mh]'):
        keys |= set(re.findall(r'\b' + macro + r'\(@' + KEY, open(path, encoding='utf-8').read()))
    return {k.replace('\\"', '"') for k in keys}


def specs(text):
    return sorted(SPEC.findall(text))


strings = json.loads(subprocess.check_output(['plutil', '-convert', 'json', '-o', '-', 'Resources/pl.lproj/Localizable.strings']))
plurals = {lang: plistlib.load(open(f'Resources/{lang}.lproj/Localizable.stringsdict', 'rb')) for lang in ('en', 'pl')}

errors = []
singular, plural = source_keys('L'), source_keys('LN')
for key in sorted(singular):
    if key not in strings:
        errors.append(f'missing pl translation: {key!r}')
    elif specs(key) != specs(strings[key]):
        errors.append(f'format mismatch: {key!r} -> {strings[key]!r}')
for key in sorted(set(strings) - singular):
    errors.append(f'unused pl translation: {key!r}')
for lang, table in plurals.items():
    for key in sorted(plural):
        forms = table.get(key, {}).get('n')
        if not forms:
            errors.append(f'missing {lang} plural: {key!r}')
            continue
        for form in ('one', 'other') + (('few', 'many') if lang == 'pl' else ()):
            if specs(forms.get(form, '')) != ['%lu']:
                errors.append(f'bad {lang} plural form {form!r} for {key!r}')
    for key in sorted(set(table) - plural):
        errors.append(f'unused {lang} plural: {key!r}')

print('\n'.join(errors) or f'check_strings: OK ({len(singular)} strings, {len(plural)} plurals)')
sys.exit(1 if errors else 0)
