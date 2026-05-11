import json
def check_duplicate_keys(pairs):
    d = {}
    for k, v in pairs:
        if k in d:
            print('DUPLICATE:', k)
        d[k] = v
    return d

with open('Trio/Sources/Localizations/Main/Localizable.xcstrings', 'r', encoding='utf-8') as f:
    json.load(f, object_pairs_hook=check_duplicate_keys)

