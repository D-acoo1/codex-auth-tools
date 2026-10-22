#!/usr/bin/env node
// Read-only sampling. RSS is not Activity Monitor's memory-footprint metric.
import {execFileSync} from 'node:child_process';
const pid = Number(process.argv[2]);
const seconds = Number(process.argv[3] ?? 60);
if (!Number.isSafeInteger(pid) || pid <= 0 || !Number.isFinite(seconds) || seconds < 1) {
  console.error('Usage: node tests/profile-balance.mjs <pid> [seconds=60]');
  process.exit(2);
}
function cpuSeconds(value) {
  const [clock, days] = value.includes('-') ? value.split('-').reverse() : [value, '0'];
  return Number(days) * 86400 + clock.split(':').reduce((sum, part) => sum * 60 + Number(part), 0);
}
function sample() {
  const [cpu, rss] = execFileSync('/bin/ps', ['-p', String(pid), '-o', 'cputime=,rss='], {encoding: 'utf8'}).trim().split(/\s+/);
  if (!cpu || !rss) throw new Error('Process exited during sampling');
  return {at: new Date().toISOString(), cpuSeconds: cpuSeconds(cpu), rssMiB: Number(rss) / 1024};
}
const samples = [sample()];
const start = performance.now();
while (performance.now() - start < seconds * 1000) {
  await new Promise(resolve => setTimeout(resolve, Math.min(5000, seconds * 1000 - (performance.now() - start))));
  samples.push(sample());
}
const elapsed = (performance.now() - start) / 1000;
const rss = samples.map(item => item.rssMiB);
console.log(JSON.stringify({pid, elapsedSeconds: elapsed,
  averageCPUPercentOfOneCore: (samples.at(-1).cpuSeconds - samples[0].cpuSeconds) / elapsed * 100,
  rssMiB: {min: Math.min(...rss), max: Math.max(...rss), last: rss.at(-1)},
  samples}, null, 2));
