"""Offline regression tests: no desktop IPC or real configuration writes."""
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


BIN = Path(__file__).resolve().parents[1] / 'bin'
sys.path.insert(0, str(BIN))
PARTICLES = 'test.display-particles'
SERVICE = 'test.service-widget'
MOCK_SHELL = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ['OMARCHY_SHELL_JSON'])
c = json.loads(p.read_text())
ident = sys.argv[3]
if sys.argv[2] == 'setPluginEnabled':
    known = any(e['id'] == ident for lane in c['bar']['layout'].values() for e in lane)
    known |= any(e['id'] == ident for e in c.get('plugins', []))
    c['disabledPlugins'] = [i for i in c.get('disabledPlugins', []) if i != ident]
    if not known:
        c['bar']['layout']['right'].append({'id': ident})
elif sys.argv[1:3] == ['plugin', 'disable']:
    c['plugins'] = [e for e in c.get('plugins', []) if e['id'] != ident]
    for lane in c['bar']['layout'].values():
        lane[:] = [e for e in lane if e['id'] != ident]
else:
    raise SystemExit('Unexpected mock command: ' + repr(sys.argv))
p.write_text(json.dumps(c))
print('ok')
'''


class SideBarEnablement(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='barctl-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.cfg = self.root / 'shell.json'
        self.extra = self.root / 'extra-bars.json'
        self.state = self.root / 'state'
        self.state.mkdir()
        tools = self.root / 'tools'
        tools.mkdir()
        for name in ('omarchy-shell', 'omarchy'):
            tool = tools / name
            tool.write_text(MOCK_SHELL)
            tool.chmod(0o755)
        self.env = dict(os.environ, OMARCHY_SHELL_JSON=str(self.cfg),
                        OMARCHY_EXTRA_BARS_JSON=str(self.extra),
                        XDG_STATE_HOME=str(self.state), PATH=str(tools) + ':' + os.environ['PATH'])
        self.save(self.cfg, {'bar': {'position': 'top', 'layout': {
            'left': [{'id': PARTICLES, 'customSetting': 'preserve'}],
            'center': [], 'right': [{'id': 'test.other'}]}},
            'plugins': [{'id': 'test.unrelated', 'setting': 42}],
            'idle': {'lock': 900}})
        self.save(self.extra, {'bars': []})

    @staticmethod
    def save(path, value):
        path.write_text(json.dumps(value))

    def read(self, path):
        return json.loads(path.read_text())

    def command(self, *args):
        p = subprocess.run([str(BIN / 'barctl-core'), *args], env=self.env,
                           text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout

    def manager(self):
        loader = importlib.machinery.SourceFileLoader('barctl_test', str(BIN / 'barctl'))
        module = importlib.util.module_from_spec(importlib.util.spec_from_loader(loader.name, loader))
        loader.exec_module(module)
        module.CFG, module.EXTRA, module.STATE = self.cfg, self.extra, self.state
        module.native_host_ready = lambda: False
        available = (PARTICLES, SERVICE, 'test.other', 's3pp3ku.bar-manager')
        module.catalog = lambda: [{'id': i, 'kinds': ['bar-widget']} for i in available]
        return module

    def assert_enabled(self, ident=PARTICLES):
        cfg = self.read(self.cfg)
        self.assertEqual(sum(e['id'] == ident for e in cfg['plugins']), 1)
        self.assertNotIn(ident, cfg.get('disabledPlugins', []))
        self.assertIn({'id': 'test.unrelated', 'setting': 42}, cfg['plugins'])
        self.assertEqual(cfg['idle'], {'lock': 900})

    def test_drop_across_every_edge_preserves_settings_and_enabled_reference(self):
        for edge in ('left', 'bottom', 'right', 'top', 'left'):
            with self.subTest(edge=edge):
                self.command('drop', PARTICLES, edge, 'left')
                self.assert_enabled()
                cfg, extra = self.read(self.cfg), self.read(self.extra)
                main = [e for lane in cfg['bar']['layout'].values() for e in lane if e['id'] == PARTICLES]
                side = [e for b in extra['bars'] for s in ('left', 'center', 'right')
                        for e in b[s] if (e.get('id') if isinstance(e, dict) else e) == PARTICLES]
                self.assertEqual(len(main) + len(side), 1)
                self.assertEqual((main or side)[0]['customSetting'], 'preserve')
                self.assertEqual(len(main), int(edge == 'top'))

    def test_drop_new_service_widget(self):
        self.command('drop', SERVICE, 'left', 'center')
        self.assert_enabled(SERVICE)

    def test_toggle_removes_only_main_duplicate(self):
        self.command('toggle', PARTICLES, 'left', 'left')
        self.command('toggle', PARTICLES, 'top', 'left')
        self.assert_enabled()
        self.assertFalse(any(e['id'] == PARTICLES for e in self.read(self.cfg)['bar']['layout']['left']))
        self.assertTrue(self.read(self.extra)['bars'])

    def test_hide_show_main_and_side_keeps_enabled(self):
        for side in (False, True):
            with self.subTest(side=side):
                if side:
                    self.command('drop', PARTICLES, 'left', 'center')
                self.command('hide', PARTICLES)
                self.assert_enabled()
                self.command('show', PARTICLES)
                self.assert_enabled()

    def test_extra_tray_and_whole_tray_drop(self):
        self.command('addtray', 'left', 'center')
        self.command('intray', PARTICLES, 'tray:t1')
        self.assert_enabled()
        self.command('drop', 'tray:t1', 'bottom', 'left')
        self.assert_enabled()
        self.assertEqual(self.read(self.extra)['bars'][0]['left'][0]['widgets'], [PARTICLES])

    def test_main_tray_keeps_enabled(self):
        cfg = self.read(self.cfg)
        cfg['bar']['layout']['right'].append({'id': 'io.github.tyrichards.tray', 'widgets': []})
        self.save(self.cfg, cfg)
        self.command('intray', PARTICLES, 'io.github.tyrichards.tray')
        self.assert_enabled()

    def test_disable_after_drop_really_disables(self):
        self.command('drop', PARTICLES, 'left', 'left')
        self.command('disable', PARTICLES)
        self.assertNotIn(PARTICLES, [e['id'] for e in self.read(self.cfg)['plugins']])
        self.assertFalse(self.read(self.extra)['bars'])

    def test_restore_old_snapshot_repairs_side_widgets_and_tray_members(self):
        module = self.manager()
        snap = module.snapshot()
        snap['bar']['layout']['left'] = []
        snap['extra'] = {'bars': [{'position': 'left', 'left': [PARTICLES], 'center': [
            {'id': 'tray:t1', 'widgets': [SERVICE, 'missing.plugin']}], 'right': [PARTICLES]}]}
        snap['disabled'] = [SERVICE]  # Explicit disable is respected, not silently overridden.
        skipped = module.apply_snapshot(snap)
        self.assert_enabled()
        self.assertEqual(sum(e['id'] == SERVICE for e in self.read(self.cfg)['plugins']), 1)
        self.assertIn(SERVICE, self.read(self.cfg)['disabledPlugins'])
        self.assertEqual(self.read(self.extra)['bars'][0]['center'][0]['widgets'], [SERVICE])
        self.assertFalse(skipped)

    def test_inline_options_save_on_every_extra_bar_edge(self):
        module = self.manager()
        # Every edge can be an extra bar, including top when main is elsewhere.
        for edge in ('top', 'left', 'right', 'bottom'):
            with self.subTest(edge=edge):
                cfg = self.read(self.cfg)
                cfg['bar']['position'] = 'bottom' if edge == 'top' else 'top'
                self.save(self.cfg, cfg)
                self.save(self.extra, {'bars': [{'position': edge, 'left': [
                    {'id': PARTICLES, 'keep': 42}, 'test.other'], 'center': [], 'right': []}]})
                module.widget_settings(PARTICLES, edge, json.dumps({'size': 20, 'id': 'wrong.plugin'}))
                lane = self.read(self.extra)['bars'][0]['left']
                self.assertEqual(lane, [{'id': PARTICLES, 'keep': 42, 'size': 20}, 'test.other'])
                module.widget_settings(PARTICLES, edge, '{"size": 21}')
                self.assertEqual(self.read(self.extra)['bars'][0]['left'][0]['size'], 21)

    def test_inline_options_are_scoped_to_selected_bar(self):
        self.save(self.extra, {'bars': [{'position': edge, 'left': [PARTICLES], 'center': [], 'right': []}
                                      for edge in ('left', 'bottom')]})
        before_cfg = self.read(self.cfg)
        self.manager().widget_settings(PARTICLES, 'left', '{"size":20}')
        self.assertEqual(self.read(self.extra)['bars'][1]['left'], [PARTICLES])
        self.assertEqual(self.read(self.cfg), before_cfg)

    def test_tray_settings_survive_move_out_and_hide_show(self):
        self.command('addtray', 'left', 'center')
        self.command('intray', PARTICLES, 'tray:t1')
        self.manager().widget_settings(PARTICLES, 'left', '{"size":20}')
        members = self.read(self.extra)['bars'][0]['center'][0]['widgets']
        self.assertEqual(members, [{'id': PARTICLES, 'customSetting': 'preserve', 'size': 20}])
        self.command('drop', PARTICLES, 'bottom', 'right')
        extra = self.read(self.extra)
        self.assertEqual(extra['bars'][0]['center'][0]['widgets'], [])
        self.assertEqual(extra['bars'][1]['right'][0]['size'], 20)
        self.assertEqual(extra['bars'][1]['right'][0]['customSetting'], 'preserve')
        self.command('hide', PARTICLES)
        self.command('show', PARTICLES)
        self.assertEqual(self.read(self.extra)['bars'][1]['right'][0]['size'], 20)
        self.assert_enabled()

    def test_disable_and_hide_find_tray_members_with_options(self):
        for action in ('hide', 'disable'):
            with self.subTest(action=action):
                self.command('intray', PARTICLES, 'tray:t1') if self.read(self.extra)['bars'] else None
                if not self.read(self.extra)['bars']:
                    self.command('addtray', 'left', 'center')
                    self.command('intray', PARTICLES, 'tray:t1')
                self.manager().widget_settings(PARTICLES, 'left', '{"size":20}')
                self.command(action, PARTICLES)
                self.assertEqual(self.read(self.extra)['bars'][0]['center'][0]['widgets'], [])

    def test_main_tray_drop_is_rejected_before_any_mutation(self):
        before_cfg, before_extra = self.read(self.cfg), self.read(self.extra)
        p = subprocess.run([str(BIN / 'barctl-core'), 'drop', 'io.github.tyrichards.tray', 'left'],
                           env=self.env, capture_output=True, text=True)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('main bar', p.stderr)
        self.assertEqual(self.read(self.cfg), before_cfg)
        self.assertEqual(self.read(self.extra), before_extra)

    def test_invalid_or_stale_widget_setting_requests_do_not_write(self):
        module = self.manager()
        before = self.read(self.extra)
        for ident, edge, payload in ((PARTICLES, 'left', '{}'), ('../bad', 'left', '{}'),
                                     (PARTICLES, 'unknown', '{}'), (PARTICLES, 'left', '[]')):
            with self.subTest(ident=ident, edge=edge, payload=payload):
                with self.assertRaises(RuntimeError):
                    module.widget_settings(ident, edge, payload)
                self.assertEqual(self.read(self.extra), before)

    def test_private_tray_service_capture_rejected_before_writing(self):
        module = self.manager()
        cfg = self.read(self.cfg)
        cfg['bar']['layout']['right'].append({'id': 's3pp3ku.tray'})
        self.save(self.cfg, cfg)
        module.catalog = lambda: [{'id': PARTICLES, 'kinds': ['bar-widget', 'service']}]
        with self.assertRaisesRegex(RuntimeError, 'companion service'):
            module.core(['intray', PARTICLES, 's3pp3ku.tray', 'top', 'top'])
        self.assertEqual(self.read(self.cfg), cfg)
        self.assertEqual(self.read(self.extra), {'bars': []})

    def test_private_tray_restore_enables_rich_members(self):
        module = self.manager()
        existing_catalog = module.catalog
        module.catalog = lambda: existing_catalog() + [{'id': 's3pp3ku.tray', 'kinds': ['bar-widget', 'service']}]
        snap = module.snapshot()
        snap['extra'] = {'bars': [{'position': 'left', 'left': [{'id': 's3pp3ku.tray',
            'widgets': [{'entry': {'id': SERVICE, 'scale': 2}, 'listed': True}]}], 'center': [], 'right': []}]}
        module.apply_snapshot(snap)
        self.assert_enabled(SERVICE)
        self.assertEqual(self.read(self.extra)['bars'][0]['left'][0]['widgets'],
                         [{'entry': {'id': SERVICE, 'scale': 2}, 'listed': True}])

    def test_native_host_allows_service_capture_with_options(self):
        module = self.manager()
        module.native_host_ready = lambda: True
        module.catalog = lambda: [{'id': PARTICLES, 'kinds': ['bar-widget', 'service']}]
        cfg = self.read(self.cfg)
        cfg['bar']['layout']['right'].append({'id': 's3pp3ku.tray'})
        self.save(self.cfg, cfg)
        module.core(['intray', PARTICLES, 's3pp3ku.tray', 'top', 'top'])
        self.assertEqual(self.read(self.cfg)['bar']['layout']['right'][-1]['widgets'],
                         [{'entry': {'id': PARTICLES, 'customSetting': 'preserve'}}])


if __name__ == '__main__':
    unittest.main()
