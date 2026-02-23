const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const SCRIPT = path.resolve(__dirname, '../scripts/validate_stream.js');
const FIXTURES = path.resolve(__dirname, 'fixtures/security');

function runTest(schema, baseDir, data) {
    const res = spawnSync('node', [SCRIPT, schema, baseDir], {
        input: data,
        env: { ...process.env, NODE_PATH: '/usr/share/nodejs' }
    });
    return {
        status: res.status,
        stdout: res.stdout.toString(),
        stderr: res.stderr.toString()
    };
}

console.log('Running security tests...');

// 1. Path traversal
console.log('Test 1: Path traversal');
const res1 = runTest(
    path.join(FIXTURES, 'base/root-traversal.json'),
    path.join(FIXTURES, 'base'),
    '{"foo": "bar"}'
);
if (res1.status !== 0 && res1.stderr.includes('Access denied')) {
    console.log('PASSED: Path traversal blocked');
} else {
    console.error('FAILED: Path traversal NOT blocked');
    console.error(res1.stderr || res1.stdout);
    process.exit(1);
}

// 2. Symlink escape
console.log('Test 2: Symlink escape');
const res2 = runTest(
    path.join(FIXTURES, 'base/root-symlink.json'),
    path.join(FIXTURES, 'base'),
    '{"foo": "bar"}'
);
if (res2.status !== 0 && res2.stderr.includes('Access denied')) {
    console.log('PASSED: Symlink escape blocked');
} else {
    console.error('FAILED: Symlink escape NOT blocked');
    console.error(res2.stderr || res2.stdout);
    process.exit(1);
}

// 3. Legit ref
console.log('Test 3: Legit ref');
const LEGIT_FIXTURES = path.resolve(__dirname, 'fixtures/ref-resolution');
const res3 = runTest(
    path.join(LEGIT_FIXTURES, 'schema-root.json'),
    LEGIT_FIXTURES,
    '{"child": {"value": "ok"}}'
);
if (res3.status === 0) {
    console.log('PASSED: Legit ref allowed');
} else {
    console.error('FAILED: Legit ref NOT allowed');
    console.error(res3.stderr || res3.stdout);
    process.exit(1);
}

console.log('All security tests passed!');
