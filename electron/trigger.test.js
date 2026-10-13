import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createGate } from './trigger.js';

test('tap latches, next tap stops', () => {
  const g = createGate();
  assert.equal(g.down(0), 'start');
  assert.equal(g.up(200), null);
  assert.equal(g.state, 'latched');
  assert.equal(g.down(3000), 'stop');
  assert.equal(g.up(3100), null);
  assert.equal(g.state, 'idle');
});

test('hold stops on release', () => {
  const g = createGate();
  assert.equal(g.down(0), 'start');
  assert.equal(g.up(1500), 'stop');
});

test('combo while armed cancels; while latched passes through', () => {
  const g = createGate();
  g.down(0);
  assert.equal(g.otherKey(), 'cancel');
  assert.equal(g.up(100), null);
  g.down(1000); g.up(1100);
  assert.equal(g.otherKey(), null);
  assert.equal(g.state, 'latched');
});

test('repeated key-down does not double-fire', () => {
  const g = createGate();
  assert.equal(g.down(0), 'start');
  assert.equal(g.down(50), null);
});

test('reset un-latches so the next press starts', () => {
  const g = createGate();
  g.down(0); g.up(100);
  g.reset();
  assert.equal(g.down(5000), 'start');
});
