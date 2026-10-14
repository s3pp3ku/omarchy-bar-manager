"""Pure four-edge layout operations for the user-owned Tray fork."""
from copy import deepcopy

TRAY = 's3pp3ku.tray'
UPSTREAM = 'io.github.tyrichards.tray'
SECTIONS = ('left', 'center', 'right')
EDGES = ('top', 'bottom', 'left', 'right')


def eid(e):
    if isinstance(e, dict):
        return eid(e['entry']) if 'entry' in e else e.get('id', '')
    return e if isinstance(e, str) else ''


def entry(e):
    e = e.get('entry', e) if isinstance(e, dict) else e
    return deepcopy(e) if isinstance(e, dict) else {'id': e}


def layouts(cfg, extra):
    main = cfg.get('bar', {}).get('position', 'top')
    yield main, cfg.setdefault('bar', {}).setdefault('layout', {})
    for b in extra.get('bars', []):
        if b.get('position') != main:
            yield b['position'], b


def layout_for(cfg, extra, edge, create=False):
    if edge not in EDGES:
        raise ValueError('Invalid bar edge')
    for pos, layout in layouts(cfg, extra):
        if pos == edge:
            return layout
    if not create:
        raise ValueError('Bar is no longer available')
    b = {'position': edge, **{s: [] for s in SECTIONS}}
    extra.setdefault('bars', []).append(b)
    return b


def locations(cfg, extra, ident, edge=None, nested=True):
    result = []
    for pos, layout in layouts(cfg, extra):
        if edge and edge != pos:
            continue
        for s in SECTIONS:
            lane = layout.get(s, [])
            for i, e in enumerate(lane):
                if eid(e) == ident:
                    result.append((pos, lane, i, e, None))
                if nested and isinstance(e, dict):
                    members = e.get('widgets', [])
                    for j, w in enumerate(members):
                        if eid(w) == ident:
                            result.append((pos, members, j, w, e))
    return result


def enabled(cfg, ident):
    if not any(eid(p) == ident for p in cfg.setdefault('plugins', [])):
        cfg['plugins'].append({'id': ident})
    cfg['disabledPlugins'] = [i for i in cfg.get('disabledPlugins', []) if i != ident]


def take(location):
    _, lane, index, e, tray = location
    lane.pop(index)
    if tray and isinstance(tray.get('order'), list):
        tray['order'] = [i for i in tray['order'] if i != eid(e)]
    return entry(e)


def insert(layout, section, e, before=''):
    section = {'top': 'left', 'middle': 'center', 'bottom': 'right'}.get(section, section)
    if section not in SECTIONS:
        raise ValueError('Invalid bar section')
    lane = layout.setdefault(section, [])
    index = next((i for i, x in enumerate(lane) if eid(x) == before), len(lane))
    lane.insert(index, e)


def migrate(cfg, extra):
    for _, layout in layouts(cfg, extra):
        for s in SECTIONS:
            for e in layout.get(s, []):
                if isinstance(e, dict) and eid(e) == UPSTREAM:
                    e['id'] = TRAY
                    for w in e.get('widgets', []):
                        enabled(cfg, eid(w))
    cfg['plugins'] = [p for p in cfg.get('plugins', []) if eid(p) != UPSTREAM]
    enabled(cfg, TRAY)
    if UPSTREAM not in cfg['disabledPlugins']:
        cfg['disabledPlugins'].append(UPSTREAM)


def move(cfg, extra, edge, section='right', before='', source_edge=''):
    target = layout_for(cfg, extra, edge, create=True)
    found = locations(cfg, extra, TRAY, source_edge or None, nested=False)
    if len(found) > 1:
        raise ValueError('Tray is on several bars; select its source bar before moving')
    source = found[0] if found else None
    existing = locations(cfg, extra, TRAY, edge, nested=False)
    if existing and (not source or existing[0] != source):
        raise ValueError('The destination already has your Tray; no settings were overwritten')
    e = take(source) if source else {'id': TRAY}
    insert(target, section, e, before)
    enabled(cfg, TRAY)


def toggle(cfg, extra, edge, section='right', saved=None):
    found = locations(cfg, extra, TRAY, edge, nested=False)
    if found:
        removed = take(found[0])
    else:
        removed = None
        insert(layout_for(cfg, extra, edge, True), section, deepcopy(saved) if saved else {'id': TRAY})
    enabled(cfg, TRAY)
    return removed


def capture(cfg, extra, ident, edge, order=None, source_edge=''):
    if ident == TRAY or ident == UPSTREAM or ident.startswith('tray:'):
        raise ValueError('A tray cannot go inside another tray')
    trays = locations(cfg, extra, TRAY, edge, nested=False)
    if len(trays) != 1:
        raise ValueError('Select a bar with exactly one s3pp3ku Tray')
    sources = locations(cfg, extra, ident, source_edge or edge)
    if not sources and not source_edge:
        sources = locations(cfg, extra, ident)
    if len(sources) != 1:
        raise ValueError('Widget is missing or ambiguous; select its source bar')
    if sources[0][4] is trays[0][3]:
        return  # Idempotent retry; do not add a duplicate wrapper.
    e = take(sources[0])
    # Re-resolve after removal: source and destination may share a lane.
    tray = locations(cfg, extra, TRAY, edge, nested=False)[0][3]
    tray.setdefault('widgets', []).append({'entry': e})
    if order is not None:
        if not isinstance(order, list) or any(not isinstance(i, str) for i in order):
            raise ValueError('Tray order must be a list of tokens')
        tray['order'] = list(dict.fromkeys(order))
    enabled(cfg, ident)


def release(cfg, extra, ident, edge, section='right', before=''):
    sources = [loc for loc in locations(cfg, extra, ident, edge) if loc[4] and eid(loc[4]) == TRAY]
    if not sources:
        return  # A repeated release must not duplicate a widget.
    e = take(sources[0])
    insert(layout_for(cfg, extra, edge), section, e, before)
    enabled(cfg, ident)


def move_widget(cfg, extra, ident, edge, section='right', before='', source_edge=''):
    """Move exactly one occurrence; never strip same-id copies on other edges."""
    if not source_edge:
        raise ValueError('Choose the source edge')
    source = locations(cfg, extra, ident, source_edge)
    if len(source) != 1:
        raise ValueError('Widget is missing or ambiguous on its source bar')
    if edge == source_edge and before == ident:
        return
    destination = locations(cfg, extra, ident, edge)
    if edge != source_edge and destination:
        raise ValueError('The destination already has this widget; nothing was overwritten')
    target = layout_for(cfg, extra, edge, True)
    e = take(source[0])
    insert(target, section, e, before)
    if not ident.startswith('tray:'):
        enabled(cfg, ident)
    for member in e.get('widgets', []):
        enabled(cfg, eid(member))


def add_drawer(cfg, extra, edge, section='right'):
    ids = {eid(e) for _, layout in layouts(cfg, extra) for s in SECTIONS for e in layout.get(s, [])}
    number = 1
    while f'tray:t{number}' in ids:
        number += 1
    ident = f'tray:t{number}'
    insert(layout_for(cfg, extra, edge, True), section, {'id': ident, 'widgets': []})
    return ident


def capture_drawer(cfg, extra, ident, drawer, edge='', source_edge=''):
    if ident in (TRAY, UPSTREAM) or ident.startswith('tray:'):
        raise ValueError('A tray cannot go inside another tray')
    targets = locations(cfg, extra, drawer, edge or None, nested=False)
    if len(targets) != 1:
        raise ValueError('Select exactly one drawer and its bar')
    target = targets[0]
    sources = locations(cfg, extra, ident, source_edge or target[0])
    if len(sources) != 1:
        raise ValueError('Select the widget source bar')
    if sources[0][4] is target[3]:
        return
    e = take(sources[0])
    tray = locations(cfg, extra, drawer, target[0], nested=False)[0][3]
    tray.setdefault('widgets', []).append(e)
    enabled(cfg, ident)


def remove_drawer(cfg, extra, drawer, edge=''):
    found = locations(cfg, extra, drawer, edge or None, nested=False)
    if len(found) != 1:
        raise ValueError('Select exactly one drawer and its bar')
    _, lane, index, e, _ = found[0]
    lane[index:index+1] = [entry(w) for w in e.get('widgets', [])]


def save_settings(cfg, extra, ident, edge, options, remembered=None):
    found = locations(cfg, extra, ident, edge)
    if not found:
        raise ValueError('Widget is no longer on the selected bar')
    for _, lane, i, old, tray in found:
        current = deepcopy((remembered or {}).get(ident, {}))
        current.update(entry(old))
        for k, v in options.items():
            if k not in ('id', 'widgets'):
                current[k] = v
        current['id'] = ident
        if tray and isinstance(old, dict) and 'entry' in old:
            lane[i] = {**old, 'entry': current}
        else:
            lane[i] = current

