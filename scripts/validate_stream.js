const fs = require('fs');
const readline = require('readline');
const Ajv = require('ajv');
const addFormats = require('ajv-formats');

const schemaPath = process.argv[2];
if (!schemaPath) {
  console.error('Usage: node validate_stream.js <schema-path>');
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

// Initialize Ajv with loose strict mode to match existing behavior
const ajv = new Ajv({ strict: false, allErrors: true });
addFormats(ajv);

let validate;
try {
  validate = ajv.compile(schema);
} catch (e) {
  console.error(`Failed to compile schema: ${e.message}`);
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
