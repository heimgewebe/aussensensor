const fs = require('fs');
const path = require('path');
const readline = require('readline');
const Ajv = require('ajv');
const addFormats = require('ajv-formats');

const schemaPath = process.argv[2];
// Optional: allow overriding base directory for $ref resolution
// (useful when validating a temp file that should resolve refs relative to original location)
const baseDirArg = process.argv[3];

if (!schemaPath) {
  console.error('Usage: node validate_stream.js <schema-path> [base-dir]');
  process.exit(1);
}

if (!fs.existsSync(schemaPath)) {
  console.error(`Schema file not found: ${schemaPath}`);
  process.exit(1);
}

let schema;
try {
  schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
} catch (e) {
  console.error(`Failed to parse schema: ${e.message}`);
  process.exit(1);
}

// Helper to load schemas from local files
async function loadSchema(uri) {
  // Remove hash fragment
  const cleanUri = uri.replace(/#.*/, '');
  if (!cleanUri) {
    return {};
  }

  // Resolve path relative to provided baseDir or schema file directory
  const effectiveBaseDir = baseDirArg || path.dirname(path.resolve(schemaPath));
  const filePath = path.resolve(effectiveBaseDir, cleanUri);

  if (!fs.existsSync(filePath)) {
    throw new Error(`Referenced schema not found: ${filePath} (from ${uri})`);
  }

  try {
    const content = fs.readFileSync(filePath, 'utf8');
    return JSON.parse(content);
  } catch (e) {
    throw new Error(`Failed to parse referenced schema ${filePath}: ${e.message}`);
  }
}

// Initialize Ajv with loose strict mode to match existing behavior
const ajv = new Ajv({
  strict: false,
  allErrors: true,
  loadSchema: loadSchema
});
addFormats(ajv);

(async () => {
  let validate;
  try {
    validate = await ajv.compileAsync(schema);
  } catch (e) {
    console.error(`Failed to compile schema (${schemaPath}): ${e.message}`);
    process.exit(1);
  }

  const rl = readline.createInterface({
    input: process.stdin,
    terminal: false
  });

  let lineCount = 0;
  let validCount = 0;

  rl.on('line', (line) => {
    lineCount++;
    const trimmed = line.trim();
    if (trimmed === '') return; // Skip empty lines

    let data;
    try {
      data = JSON.parse(trimmed);
    } catch (e) {
      console.error(`Error parsing JSON on line ${lineCount}: ${e.message}`);
      process.exit(1);
    }

    if (!validate(data)) {
      console.error(`Validation error on line ${lineCount}:`);
      console.error(ajv.errorsText(validate.errors));
      process.exit(1);
    }
    validCount++;
  });

  rl.on('close', () => {
    // If no valid records were processed (e.g. empty file or all empty lines),
    // exit with code 2 to match existing validate.sh behavior (no data).
    if (validCount === 0) {
      process.exit(2);
    }
    process.exit(0);
  });
})();
