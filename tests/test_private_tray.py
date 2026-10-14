"""Four-edge Tray tests, independent of the desktop session."""
from copy import deepcopy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'bin'))
import tray_layout as model


class PrivateTray(unittest.TestCase):
    def setUp(self):
        self.cfg = {'version': 1, 'bar': {'position': 'top', 'layout': {
            'left': [{'id': 'test.clock', 'format': 'keep-me'}], 'center': [],
            'right': [{'id': model.UPSTREAM, 'hidden': ['test.icon'], 'widgets': [
                {'entry': {'id': 'test.mouse', 'scale': 2}, 'listed': True}], 'order': ['test.mouse']}]}},
            'plugins': [{'id': 'test.unrelated', 'option': 9}], 'idle': {'lock': 900}}
        self.extra = {'bars': []}
        model.migrate(self.cfg, self.extra)

    def tray(self, edge):
        return model.locations(self.cfg, self.extra, model.TRAY, edge, False)[0][3]

    def test_migration_preserves_every_upstream_option(self):
        e = self.tray('top')
        self.assertEqual(e['hidden'], ['test.icon'])
        self.assertEqual(e['widgets'][0], {'entry': {'id': 'test.mouse', 'scale': 2}, 'listed': True})
        self.assertIn(model.UPSTREAM, self.cfg['disabledPlugins'])
        self.assertEqual(self.cfg['idle'], {'lock': 900})
        self.assertIn({'id': 'test.unrelated', 'option': 9}, self.cfg['plugins'])

    def test_tray_moves_roundtrip_across_all_four_edges(self):
        expected = deepcopy(self.tray('top'))
        source = 'top'
        for edge in ('right', 'bottom', 'left', 'top'):
            with self.subTest(edge=edge):
                model.move(self.cfg, self.extra, edge, 'right', source_edge=source)
                self.assertEqual(self.tray(edge), expected)
                self.assertEqual(len(model.locations(self.cfg, self.extra, model.TRAY, nested=False)), 1)
                source = edge

    def test_independent_trays_and_settings_on_all_four_edges(self):
        for edge in ('left', 'bottom', 'right'):
            model.toggle(self.cfg, self.extra, edge)
        for i, edge in enumerate(model.EDGES):
            model.save_settings(self.cfg, self.extra, model.TRAY, edge, {'hidden': [str(i)]})
        for i, edge in enumerate(model.EDGES):
            self.assertEqual(self.tray(edge)['hidden'], [str(i)])

    def test_ambiguous_move_and_occupied_destination_never_overwrite(self):
        model.toggle(self.cfg, self.extra, 'left')
        snapshot = deepcopy((self.cfg, self.extra))
        with self.assertRaises(ValueError):
            model.move(self.cfg, self.extra, 'bottom')
        # Empty destination creation is in memory only; caller writes only on success.
        self.cfg, self.extra = deepcopy(snapshot)
        with self.assertRaises(ValueError):
            model.move(self.cfg, self.extra, 'left', source_edge='top')
        self.assertEqual((self.cfg, self.extra), snapshot)

    def test_capture_release_and_member_settings_on_every_edge(self):
        for edge in ('top', 'left', 'bottom', 'right'):
            with self.subTest(edge=edge):
                if edge != 'top':
                    model.move(self.cfg, self.extra, edge)
                layout = model.layout_for(self.cfg, self.extra, edge)
                layout.setdefault('left', []).append({'id': 'test.member', 'custom': 42})
                model.capture(self.cfg, self.extra, 'test.member', edge, ['test.mouse', 'test.member'])
                model.capture(self.cfg, self.extra, 'test.member', edge)
                self.assertEqual(sum(model.eid(w) == 'test.member' for w in self.tray(edge)['widgets']), 1)
                model.save_settings(self.cfg, self.extra, 'test.member', edge, {'size': 20})
                wrapper = next(w for w in self.tray(edge)['widgets'] if model.eid(w) == 'test.member')
                self.assertEqual(wrapper['entry'], {'id': 'test.member', 'custom': 42, 'size': 20})
                model.release(self.cfg, self.extra, 'test.member', edge, 'center')
                model.release(self.cfg, self.extra, 'test.member', edge, 'center')
                self.assertEqual(layout['center'], [{'id': 'test.member', 'custom': 42, 'size': 20}])
                layout['center'].clear()

    def test_same_lane_capture_resolves_after_removal(self):
        model.release(self.cfg, self.extra, 'test.mouse', 'top', 'right', model.TRAY)
        model.capture(self.cfg, self.extra, 'test.mouse', 'top')
        self.assertEqual(self.tray('top')['widgets'][0]['entry']['scale'], 2)

    def test_cross_bar_capture_preserves_source_options(self):
        model.toggle(self.cfg, self.extra, 'bottom')
        model.capture(self.cfg, self.extra, 'test.clock', 'bottom', source_edge='top')
        self.assertEqual(self.tray('bottom')['widgets'][0]['entry'], {'id': 'test.clock', 'format': 'keep-me'})
        self.assertEqual(self.cfg['bar']['layout']['left'], [])

    def test_nested_trays_are_rejected_without_mutation(self):
        before = deepcopy((self.cfg, self.extra))
        for ident in (model.TRAY, model.UPSTREAM, 'tray:t1'):
            with self.assertRaises(ValueError):
                model.capture(self.cfg, self.extra, ident, 'top')
        self.assertEqual((self.cfg, self.extra), before)

    def test_toggle_remembers_whole_tray_for_restore(self):
        expected = deepcopy(self.tray('top'))
        removed = model.toggle(self.cfg, self.extra, 'top')
        model.toggle(self.cfg, self.extra, 'top', saved=removed)
        self.assertEqual(self.tray('top'), expected)

    def test_main_bar_can_be_any_edge(self):
        for edge in model.EDGES:
            self.cfg['bar']['position'] = edge
            self.assertEqual(model.layout_for(self.cfg, self.extra, edge), self.cfg['bar']['layout'])

    def test_stale_release_is_idempotent(self):
        before = deepcopy((self.cfg, self.extra))
        model.release(self.cfg, self.extra, 'missing.widget', 'top')
        self.assertEqual((self.cfg, self.extra), before)

    def test_member_save_preserves_wrapper_metadata(self):
        model.save_settings(self.cfg, self.extra, 'test.mouse', 'top', {'scale': 3})
        self.assertTrue(self.tray('top')['widgets'][0]['listed'])
        self.assertEqual(self.tray('top')['widgets'][0]['entry']['scale'], 3)

    def test_native_moves_only_source_occurrence(self):
        model.layout_for(self.cfg, self.extra, 'left', True)['left'] = [{'id': 'test.clock', 'format': 'separate'}]
        model.move_widget(self.cfg, self.extra, 'test.clock', 'bottom', 'right', source_edge='top')
        self.assertEqual(model.layout_for(self.cfg, self.extra, 'left')['left'], [{'id': 'test.clock', 'format': 'separate'}])
        self.assertEqual(model.layout_for(self.cfg, self.extra, 'bottom')['right'], [{'id': 'test.clock', 'format': 'keep-me'}])

    def test_native_drop_rejects_occupied_edge_without_loss(self):
        model.layout_for(self.cfg, self.extra, 'left', True)['left'] = [{'id': 'test.clock', 'format': 'separate'}]
        before = deepcopy((self.cfg, self.extra))
        with self.assertRaises(ValueError):
            model.move_widget(self.cfg, self.extra, 'test.clock', 'left', source_edge='top')
        self.assertEqual((self.cfg, self.extra), before)

    def test_native_move_out_of_drawer_preserves_options(self):
        model.move_widget(self.cfg, self.extra, 'test.mouse', 'left', 'center', source_edge='top')
        self.assertEqual(model.layout_for(self.cfg, self.extra, 'left')['center'], [{'id': 'test.mouse', 'scale': 2}])
        self.assertEqual(self.tray('top')['order'], [])

    def test_native_drawers_capture_save_restore_on_all_edges(self):
        for edge in model.EDGES:
            with self.subTest(edge=edge):
                drawer = model.add_drawer(self.cfg, self.extra, edge)
                model.layout_for(self.cfg, self.extra, edge)['left'].append({'id': 'test.service', 'volume': 7})
                model.capture_drawer(self.cfg, self.extra, 'test.service', drawer, edge, edge)
                model.save_settings(self.cfg, self.extra, 'test.service', edge, {'volume': 8})
                model.remove_drawer(self.cfg, self.extra, drawer, edge)
                found = model.locations(self.cfg, self.extra, 'test.service', edge)
                self.assertEqual(len(found), 1)
                self.assertIsNone(found[0][4])
                self.assertEqual(found[0][3]['volume'], 8)

    def test_native_drawer_capture_moves_only_chosen_edge(self):
        drawer = model.add_drawer(self.cfg, self.extra, 'bottom')
        model.layout_for(self.cfg, self.extra, 'left', True)['left'] = [{'id':'test.clock','format':'separate'}]
        model.capture_drawer(self.cfg, self.extra, 'test.clock', drawer, 'bottom', 'top')
        self.assertEqual(model.locations(self.cfg,self.extra,'test.clock','bottom')[0][3]['format'], 'keep-me')
        self.assertEqual(model.locations(self.cfg,self.extra,'test.clock','left')[0][3]['format'], 'separate')


if __name__ == '__main__':
    unittest.main()
