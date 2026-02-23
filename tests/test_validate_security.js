const { spawnSync } = require('child_process');
const path = require('path');
const fs = require('fs');

const SCRIPT = path.resolve(__dirname, '../scripts/validate_stream.js');
const FIXTURES = path.resolve(__dirname, 'fixtures/security');

function runTest(schema, baseDir, data) {
    const res = spawnSync('node', [SCRIPT, schema, baseDir], {
        input: data,
        env: process.env
    });
    return {
        status: res.status,
        stdout: res.stdout.toString(),
        stderr: res.stderr.toString()
    };
}

console.log('Running security tests...');

// 1. Symlink escape (file)
// A file symlink inside base points to a file outside.
// realpath guard must deny access.
console.log('Test 1: Symlink escape (file)');
const baseDir = path.join(FIXTURES, 'base');
const traversalLink = path.join(baseDir, 'traversal-link.json');
let traversalCreated = false;

try {
    if (fs.existsSync(traversalLink)) {
        fs.unlinkSync(traversalLink);
    }
    fs.symlinkSync('../outside.json', traversalLink, 'file');
    traversalCreated = true;
} catch (e) {
    console.log(`SKIPPED: Symlink escape (file) test (reason: could not create symlink - ${e.message})`);
}

if (traversalCreated) {
    const res1 = runTest(
        path.join(FIXTURES, 'base/root-traversal.json'),
        baseDir,
        '{"foo": "bar"}'
    );
    if (res1.status !== 0 && res1.stderr.includes('Access denied')) {
        console.log('PASSED: Symlink escape (file) blocked');
    } else {
        console.error('FAILED: Symlink escape (file) NOT blocked correctly');
        console.error('Exit code:', res1.status);
        console.error('Stderr:', res1.stderr);
        try { fs.unlinkSync(traversalLink); } catch (e) {}
        process.exit(1);
    }
    try { fs.unlinkSync(traversalLink); } catch (e) {}
}

// 2. Symlink escape (directory)
console.log('Test 2: Symlink escape (directory)');
const linkPath = path.join(baseDir, 'link-to-parent');
let symlinkCreated = false;

try {
    if (fs.existsSync(linkPath)) {
        fs.unlinkSync(linkPath);
    }
    fs.symlinkSync('..', linkPath, 'dir');
    symlinkCreated = true;
} catch (e) {
    console.log(`SKIPPED: Symlink escape (directory) test (reason: could not create symlink - ${e.message})`);
}

if (symlinkCreated) {
    // Schema refers to link-to-parent/outside.json which resolves (via symlinked directory) to ../outside.json outside baseDir.
    const res2 = runTest(
        path.join(baseDir, 'root-symlink.json'),
        baseDir,
        '{"foo": "bar"}'
    );
    if (res2.status !== 0 && res2.stderr.includes('Access denied')) {
        console.log('PASSED: Symlink escape (directory) blocked');
    } else {
        console.error('FAILED: Symlink escape (directory) NOT blocked correctly');
        console.error('Exit code:', res2.status);
        console.error('Stderr:', res2.stderr);
        try { fs.unlinkSync(linkPath); } catch (e) {}
        process.exit(1);
    }
    try { fs.unlinkSync(linkPath); } catch (e) {}
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

console.log('All security tests completed successfully!');
