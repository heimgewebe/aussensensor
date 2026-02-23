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

// 1. Path traversal (absolute path escape)
// We generate the fixture at runtime to ensure the absolute path is correct for this environment.
console.log('Test 1: Path traversal (absolute path escape)');
const traversalSchemaPath = path.join(FIXTURES, 'base/root-traversal.json');
const outsideFile = path.join(FIXTURES, 'outside.json');
const schema = {
    type: "object",
    properties: {
        foo: { "$ref": outsideFile }
    }
};
fs.writeFileSync(traversalSchemaPath, JSON.stringify(schema));

const res1 = runTest(
    traversalSchemaPath,
    path.join(FIXTURES, 'base'),
    '{"foo": "bar"}'
);
if (res1.status !== 0 && res1.stderr.includes('Access denied')) {
    console.log('PASSED: Path traversal blocked');
} else {
    console.error('FAILED: Path traversal NOT blocked correctly');
    console.error('Exit code:', res1.status);
    console.error('Stderr:', res1.stderr);
    process.exit(1);
}

// 2. Symlink escape
console.log('Test 2: Symlink escape');
const linkPath = path.join(FIXTURES, 'base', 'link-to-parent');
let symlinkCreated = false;

try {
    if (fs.existsSync(linkPath)) {
        fs.unlinkSync(linkPath);
    }
    fs.symlinkSync('..', linkPath, 'dir');
    symlinkCreated = true;
} catch (e) {
    console.log(`SKIPPED: Symlink escape test (reason: could not create symlink - ${e.message})`);
}

if (symlinkCreated) {
    // Schema refers to link-to-parent/outside.json which resolves to ../outside.json
    const symlinkSchemaPath = path.join(FIXTURES, 'base/root-symlink.json');
    const symlinkSchema = {
        type: "object",
        properties: {
            foo: { "$ref": "link-to-parent/outside.json" }
        }
    };
    fs.writeFileSync(symlinkSchemaPath, JSON.stringify(symlinkSchema));

    const res2 = runTest(
        symlinkSchemaPath,
        path.join(FIXTURES, 'base'),
        '{"foo": "bar"}'
    );
    if (res2.status !== 0 && res2.stderr.includes('Access denied')) {
        console.log('PASSED: Symlink escape blocked');
    } else {
        console.error('FAILED: Symlink escape NOT blocked correctly');
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
