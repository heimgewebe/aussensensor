const fs = require('fs');
const readline = require('readline');

// Try to load ajv
let Ajv;
let addFormats;
try {
  Ajv = require('ajv');
  addFormats = require('ajv-formats');
} catch (e) {
  console.error('Error: ajv or ajv-formats not found. Make sure to run this with npx supplying the dependencies.');
  process.exit(1);
}

const schemaPath = process.argv[2];
const filename = process.argv[3] || 'stdin';

if (!schemaPath) {
  console.error('Usage: node validate_stream.js <schema_path> [filename]');
  process.exit(1);
}

let schema;
try {
  schema = JSON.parse(fs.readFileSync(schemaPath, 'utf8'));
} catch (e) {
  console.error(`Error reading schema: ${e.message}`);
  process.exit(1);
}

// Initialize Ajv
// The shell script uses --spec=draft7 --strict=false.
// We use loose strict mode to allow extra properties if needed, matching current behavior.
const ajv = new Ajv({
  strict: false,
  allErrors: true
});
addFormats(ajv);

let validate;
try {
  validate = ajv.compile(schema);
} catch (e) {
  console.error(`Error compiling schema: ${e.message}`);
  process.exit(1);
}

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

let lineNum = 0;
let hasError = false;
let seen = 0;

rl.on('line', (line) => {
  lineNum++;
  // Ignore empty lines (whitespace only)
  if (!line.trim()) return;
  seen++;

  let data;
  try {
    data = JSON.parse(line);
  } catch (e) {
    console.error(`Fehler: Ungültiges JSON in Zeile ${lineNum} in '${filename}'`);
    // We can verify if validate.sh printed the line content. It did not for invalid JSON,
    // it only printed "Validation failed" if validation failed.
    // But parse error is also a failure.
    hasError = true;
    return;
  }

  const valid = validate(data);
  if (!valid) {
    console.error(`Fehler: Validierung fehlgeschlagen (Zeile ${lineNum} in '${filename}').`);
    console.error('JSON-Objekt:');
    console.error(line);
    console.error('Details:');
    if (validate.errors) {
      validate.errors.forEach(err => {
        console.error(`${err.instancePath || 'root'} ${err.message}`);
      });
    }
    hasError = true;
  }
});

rl.on('close', () => {
  if (seen === 0) {
    // Return 2 to indicate no data found (for REQUIRE_NONEMPTY logic in bash)
    process.exit(2);
  }

  process.exit(hasError ? 1 : 0);
});
