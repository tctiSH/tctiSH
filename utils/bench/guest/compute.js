// node_compute's kernels: small loops that V8 optimizes early, so the time is mostly its optimized
// code rather than its parser, interpreter or tiering (node_prettier covers those). The results
// fold into one checksum, printed at the end. Deterministic: no Math.random, clock or hash order.

"use strict";

const SCALE = Number(process.argv[2] || 1);

// A linear congruential generator, so the data is the same every run.
function lcg(seed) {
  let s = seed >>> 0;
  return () => (s = (Math.imul(s, 1664525) + 1013904223) >>> 0);
}

// Floating point over typed arrays: a Mandelbrot set, counted.
function mandelbrot(size) {
  const counts = new Uint16Array(size * size);
  for (let y = 0; y < size; y++) {
    for (let x = 0; x < size; x++) {
      const cr = (2.5 * x) / size - 2.0, ci = (2.0 * y) / size - 1.0;
      let zr = 0, zi = 0, i = 0;
      while (i < 200 && zr * zr + zi * zi < 4) {
        const t = zr * zr - zi * zi + cr;
        zi = 2 * zr * zi + ci;
        zr = t;
        i++;
      }
      counts[y * size + x] = i;
    }
  }
  let sum = 0;
  for (const c of counts) sum = (sum + c) | 0;
  return sum;
}

// Objects, property access and a comparator sort: records sorted three ways.
function records(n) {
  const next = lcg(1);
  const rows = [];
  for (let i = 0; i < n; i++) {
    const group = next() % 97, score = (next() % 100000) / 7, name = "r" + (next() % 5000);
    rows.push({ id: i, group, score, name });
  }
  let sum = 0;
  rows.sort((a, b) => a.group - b.group || a.score - b.score);
  sum = (sum + rows[0].id + rows[n - 1].id) | 0;
  rows.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : a.id - b.id));
  sum = (sum + rows[0].id + rows[n >> 1].id) | 0;
  rows.sort((a, b) => b.score - a.score);
  return (sum + rows[0].id) | 0;
}

// Strings: JSON in and out, string building and regular expressions.
function text(n) {
  const next = lcg(2);
  const doc = [];
  for (let i = 0; i < n; i++) {
    const tags = ["a" + (next() % 13), "b" + (next() % 7)];
    doc.push({ key: "k" + i, tags, value: next() % 1000 });
  }
  let sum = 0;
  for (let round = 0; round < 4; round++) {
    const json = JSON.stringify(doc);
    const back = JSON.parse(json);
    sum = (sum + json.length + back.length) | 0;
    const csv = back.map((r) => `${r.key},${r.tags.join(";")},${r.value}`).join("\n");
    sum = (sum + csv.replace(/a(\d+);b(\d+)/g, (_, p, q) => q + p).length) | 0;
    sum = (sum + (csv.match(/,9\d\d$/gm) || []).length) | 0;
  }
  return sum;
}

// Maps and sets keyed by strings and numbers: a word count and a graph walk.
function collections(n) {
  const next = lcg(3);
  const counts = new Map();
  for (let i = 0; i < n; i++) {
    const w = "w" + (next() % 4096);
    counts.set(w, (counts.get(w) || 0) + 1);
  }
  const edges = new Map();
  for (let i = 0; i < n; i++) {
    const a = next() % 20000, b = next() % 20000;
    if (!edges.has(a)) edges.set(a, []);
    edges.get(a).push(b);
  }
  const seen = new Set([0]);
  const queue = [0];
  while (queue.length) {
    for (const b of edges.get(queue.shift()) || []) {
      if (!seen.has(b)) {
        seen.add(b);
        queue.push(b);
      }
    }
  }
  let sum = seen.size;
  for (const [w, c] of counts) sum = (sum + w.length * c) | 0;
  return sum;
}

let check = 0;
for (const [name, fn, arg] of [
  ["mandelbrot", mandelbrot, 400],
  ["records", records, 60000],
  ["text", text, 20000],
  ["collections", collections, 200000],
]) {
  for (let i = 0; i < SCALE; i++) check = (Math.imul(check, 31) + fn(arg)) | 0;
}
console.log("checksum", (check >>> 0).toString(16));
